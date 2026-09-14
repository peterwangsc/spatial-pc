#!/usr/bin/env python3
"""Create a seven-day, explicitly provisioned mTLS pair for the M1 experiment.

This is not the product's discovery/code-confirmation pairing flow. Transfer the
client enrollment over the trusted local device connection, never over Bonjour.
"""
import argparse, base64, datetime, hashlib, json, os
from pathlib import Path
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import pkcs12
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

def create_pair(directory, host, port):
    directory.mkdir(parents=True, exist_ok=False, mode=0o700)
    now = datetime.datetime.now(datetime.timezone.utc)
    root_key = ec.generate_private_key(ec.SECP256R1())
    root_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Spatial PC lab CA')])
    def certificate(key, name, usage=None):
        builder = (x509.CertificateBuilder().subject_name(name).issuer_name(root_name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now-datetime.timedelta(minutes=5))
            .not_valid_after(now+datetime.timedelta(days=7))
            .add_extension(x509.BasicConstraints(ca=usage is None, path_length=0 if usage is None else None), True)
            .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), False)
            .add_extension(x509.AuthorityKeyIdentifier.from_issuer_public_key(root_key.public_key()), False)
            .add_extension(x509.KeyUsage(digital_signature=True, content_commitment=False,
                key_encipherment=False, data_encipherment=False, key_agreement=False,
                key_cert_sign=usage is None, crl_sign=usage is None,
                encipher_only=None, decipher_only=None), True))
        if usage:
            builder = builder.add_extension(x509.ExtendedKeyUsage([usage]), False)
        if usage == ExtendedKeyUsageOID.SERVER_AUTH:
            builder = builder.add_extension(x509.SubjectAlternativeName([x509.DNSName('spatialpc.test')]), False)
        return builder.sign(root_key, hashes.SHA256())
    root = certificate(root_key, root_name)
    host_key, client_key = [ec.generate_private_key(ec.SECP256R1()) for _ in range(2)]
    name = lambda value: x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, value)])
    server = certificate(host_key, name('Spatial PC lab host'), ExtendedKeyUsageOID.SERVER_AUTH)
    client = certificate(client_key, name('Spatial PC lab headset'), ExtendedKeyUsageOID.CLIENT_AUTH)
    pem = serialization.Encoding.PEM
    der = serialization.Encoding.DER
    password = base64.urlsafe_b64encode(os.urandom(24))
    p12 = pkcs12.serialize_key_and_certificates(b'Spatial PC lab', client_key, client, [root],
        serialization.BestAvailableEncryption(password))
    enrollment = dict(host=host, port=port, serverName='spatialpc.test',
        serverSHA256=server.fingerprint(hashes.SHA256()).hex(),
        rootDER=base64.b64encode(root.public_bytes(der)).decode(),
        identityPKCS12=base64.b64encode(p12).decode(), password=password.decode())
    files = {
        'lab-pair.json': json.dumps(enrollment),
        'server.pem': server.public_bytes(pem).decode(),
        'root.pem': root.public_bytes(pem).decode(),
        'server-key.pem': host_key.private_bytes(pem, serialization.PrivateFormat.PKCS8,
                                               serialization.NoEncryption()).decode(),
        'client.pem': client.public_bytes(pem).decode(),
        'client-key.pem': client_key.private_bytes(pem, serialization.PrivateFormat.PKCS8,
                                                 serialization.NoEncryption()).decode(),
        'server-policy.json': json.dumps(dict(clientSHA256=client.fingerprint(hashes.SHA256()).hex(), port=port))
    }
    for filename, content in files.items():
        fd = os.open(directory/filename, os.O_WRONLY|os.O_CREAT|os.O_EXCL, 0o600)
        with os.fdopen(fd, 'w') as file: file.write(content)
    # The CA private key is deliberately not persisted.
    print('Created private lab credentials; no key material printed.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--host', required=True)
    parser.add_argument('--port', type=int, default=47991)
    args = parser.parse_args()
    create_pair(args.directory, args.host, args.port)
