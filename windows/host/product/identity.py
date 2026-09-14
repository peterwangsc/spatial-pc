"""Per-user certificate identity and atomic, DPAPI-protected paired-device state."""
import base64
import copy
import datetime as dt
import json
import os
from pathlib import Path
import secrets
import ssl
import tempfile
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID
from .windows_security import dpapi, protect_directory

PEM, DER = serialization.Encoding.PEM, serialization.Encoding.DER


def private_pem(key):
    return key.private_bytes(PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode('ascii')


def issue_certificate(public_key, name, issuer, issuer_key, days, usage=None, server_name=None):
    now = dt.datetime.now(dt.timezone.utc)
    certificate = (x509.CertificateBuilder().subject_name(x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)]))
        .issuer_name(issuer).public_key(public_key).serial_number(x509.random_serial_number())
        .not_valid_before(now-dt.timedelta(minutes=5)).not_valid_after(now+dt.timedelta(days=days))
        .add_extension(x509.BasicConstraints(ca=usage is None, path_length=0 if usage is None else None), True)
        .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False, key_encipherment=False,
            data_encipherment=False, key_agreement=False, key_cert_sign=usage is None, crl_sign=usage is None,
            encipher_only=None, decipher_only=None), True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(public_key), False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(issuer_key.public_key()), False))
    if usage:
        certificate = certificate.add_extension(x509.ExtendedKeyUsage([usage]), False)
    if server_name:
        certificate = certificate.add_extension(x509.SubjectAlternativeName([x509.DNSName(server_name)]), False)
    return certificate.sign(issuer_key, hashes.SHA256())


class Identity:
    def __init__(self, directory, protect=dpapi, secure_directory=protect_directory):
        self.directory = Path(directory)
        secure_directory(self.directory)
        self.protect = protect
        self.path = self.directory/'identity.dat'
        if self.path.exists():
            if self.path.stat().st_size > 1024*1024:
                raise ValueError('Saved identity exceeds its limit')
            self.state = json.loads(protect(self.path.read_bytes(), decrypt=True))
            if self.state.get('version') != 1 or len(self.state.get('devices', [])) > 10:
                raise ValueError('Saved identity version or device limit is invalid')
        else:
            host_id = secrets.token_hex(16)
            ca_key, server_key = [ec.generate_private_key(ec.SECP256R1()) for _ in range(2)]
            ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Spatial PC '+host_id)])
            server_name = 'spatialpc-'+host_id+'.local'
            ca = issue_certificate(ca_key.public_key(), 'Spatial PC '+host_id, ca_name, ca_key, 3650)
            server = issue_certificate(server_key.public_key(), 'Spatial PC host', ca_name, ca_key, 365,
                                       ExtendedKeyUsageOID.SERVER_AUTH, server_name)
            self.state = dict(version=1, hostId=host_id, serverName=server_name, caKey=private_pem(ca_key),
                serverKey=private_pem(server_key), caCertificate=ca.public_bytes(PEM).decode('ascii'),
                serverCertificate=server.public_bytes(PEM).decode('ascii'), devices=[], accessEnabled=False,
                bindAddress=None)
            self.save(self.state)
        self.ca = x509.load_pem_x509_certificate(self.state['caCertificate'].encode('ascii'))
        self.server = x509.load_pem_x509_certificate(self.state['serverCertificate'].encode('ascii'))
        self.ca_key = serialization.load_pem_private_key(self.state['caKey'].encode('ascii'), None)
        self.server_key = serialization.load_pem_private_key(self.state['serverKey'].encode('ascii'), None)
        for certificate, key in [(self.ca, self.ca_key), (self.server, self.server_key)]:
            if certificate.public_key().public_numbers() != key.public_key().public_numbers():
                raise ValueError('Saved certificate and key do not match')
        self.server.verify_directly_issued_by(self.ca)

    def save(self, state):
        payload = self.protect(json.dumps(state, separators=(',', ':')).encode('utf-8'))
        if len(payload) > 1024*1024:
            raise ValueError('Saved identity exceeds its limit')
        descriptor, temporary = tempfile.mkstemp(prefix='identity-', suffix='.tmp', dir=self.directory)
        try:
            with os.fdopen(descriptor, 'wb') as file:
                file.write(payload); file.flush(); os.fsync(file.fileno())
            os.replace(temporary, self.path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        self.state = state

    def configure(self, **values):
        if set(values)-{'accessEnabled', 'bindAddress'}:
            raise ValueError('Unknown setting')
        state = copy.deepcopy(self.state); state.update(values); self.save(state)

    def enroll(self, public_key, name, allowed=None):
        if len(self.state['devices']) >= 10:
            raise ValueError('Remove a paired device before adding another')
        if not isinstance(public_key, ec.EllipticCurvePublicKey) or not isinstance(public_key.curve, ec.SECP256R1):
            raise ValueError('Unsupported device key')
        device_id = secrets.token_hex(16)
        certificate = issue_certificate(public_key, 'Spatial PC device '+device_id, self.ca.subject, self.ca_key,
                                        365, ExtendedKeyUsageOID.CLIENT_AUTH)
        device = dict(id=device_id, name=name, certificate=base64.b64encode(certificate.public_bytes(DER)).decode('ascii'),
                      fingerprint=certificate.fingerprint(hashes.SHA256()).hex(),
                      pairedAt=dt.datetime.now(dt.timezone.utc).isoformat())
        state = copy.deepcopy(self.state); state['devices'].append(device)
        if allowed is not None and not allowed():
            raise ValueError('Pairing approval expired')
        self.save(state)
        return device

    def revoke(self, device_id):
        state = copy.deepcopy(self.state)
        state['devices'] = [item for item in state['devices'] if item['id'] != device_id]
        self.save(state)

    def device_for(self, fingerprint):
        return next((item for item in self.state['devices'] if secrets.compare_digest(item['fingerprint'], fingerprint)), None)

    def tls_context(self, pairing=False):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = context.maximum_version = ssl.TLSVersion.TLSv1_3
        context.num_tickets = 0
        context.options |= ssl.OP_NO_TICKET
        context.set_alpn_protocols(['spatialpc-pair/1' if pairing else 'spatialpc/1'])
        context.verify_mode = ssl.CERT_NONE if pairing else ssl.CERT_REQUIRED
        context.load_verify_locations(cadata=self.state['caCertificate'])
        # OpenSSL's API takes filenames. Only an encrypted private key exists on
        # disk, inside the protected directory, and is removed after loading.
        password = secrets.token_bytes(32)
        encrypted = self.server_key.private_bytes(PEM, serialization.PrivateFormat.PKCS8,
                                                   serialization.BestAvailableEncryption(password))
        with tempfile.TemporaryDirectory(prefix='tls-', dir=self.directory) as temporary:
            cert_path, key_path = Path(temporary)/'server.pem', Path(temporary)/'key.pem'
            cert_path.write_text(self.state['serverCertificate'], encoding='ascii')
            key_path.write_bytes(encrypted)
            context.load_cert_chain(cert_path, key_path, password=password)
        return context
