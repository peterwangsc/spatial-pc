using System;
using System.Collections.Generic;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;

// The GUID-returning methods cannot be invoked through COM's dynamic binder.
// Vtable order follows the Windows SDK netlistmgr.h INetworkConnection interface.
[ComImport, Guid("DCB00005-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
internal interface INetworkConnection {
    [return:MarshalAs(UnmanagedType.Interface)] object GetNetwork();
    bool IsConnectedToInternet { [return:MarshalAs(UnmanagedType.VariantBool)] get; }
    bool IsConnected { [return:MarshalAs(UnmanagedType.VariantBool)] get; }
    int GetConnectivity();
    Guid GetConnectionId();
    Guid GetAdapterId();
    int GetDomainType();
}

internal static class NetworkPolicy {
    internal static Dictionary<string,string> PrivateAddresses() {
        var result=new Dictionary<string,string>();
        var adapters=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        dynamic manager=Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("DCB00C01-570F-4A9B-8D69-199FDBA5723B")));
        foreach(object item in manager.GetNetworkConnections()) {
            var connection=(INetworkConnection)item;
            dynamic network=connection.GetNetwork();
            if((int)network.GetCategory()==1)adapters.Add(connection.GetAdapterId().ToString());
        }
        foreach(var adapter in NetworkInterface.GetAllNetworkInterfaces())
            if(adapter.OperationalStatus==OperationalStatus.Up&&adapters.Contains(adapter.Id.Trim('{','}')))
                foreach(var address in adapter.GetIPProperties().UnicastAddresses)
                    if(address.Address.AddressFamily==AddressFamily.InterNetwork)
                        result[adapter.Name+" · "+address.Address]=address.Address.ToString();
        return result;
    }
}
