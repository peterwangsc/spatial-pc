"""Assigned-address selection; never resolve an arbitrary host or bind wildcard."""
import ipaddress
import socket
import ifaddr


def normalize(address):
    ip=ipaddress.ip_address(address)
    if ip.is_unspecified or ip.is_multicast:raise ValueError('Choose an assigned unicast address')
    if ip.version==6:
        if ip.ipv4_mapped:raise ValueError('Choose an explicit IPv4 or IPv6 address')
        if ip.scope_id is not None and (not ip.scope_id.isascii() or not ip.scope_id.isdecimal() or not 0<int(ip.scope_id)<2**32):
            raise ValueError('Invalid IPv6 interface scope')
        if ip.is_link_local and ip.scope_id is None:raise ValueError('IPv6 link-local address needs its interface scope')
    return str(ip)


def local_addresses():
    result={}
    for adapter in ifaddr.get_adapters():
        for entry in adapter.ips:
            raw=entry.ip
            if isinstance(raw,str):address=str(ipaddress.ip_address(raw))
            else:
                ip=ipaddress.ip_address(raw[0].split('%')[0]);address=str(ip)
                if ip.is_link_local:
                    scope=raw[2] or adapter.index
                    if not scope:continue
                    address+='%'+str(scope)
            result[address]=adapter.index
    return result


def socket_address(address,port):
    ip=ipaddress.ip_address(normalize(address))
    if ip.version==4:return socket.AF_INET,(str(ip),port)
    return socket.AF_INET6,(str(ip).split('%')[0],port,0,int(ip.scope_id or 0))
