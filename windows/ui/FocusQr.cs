// Optional development QR renderer. Credential payload exists only in memory.
using System;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Security.Cryptography;

internal static class FocusQr {
    const string Expected="5ae2792c76262943a4e34140bbd64b2aa7d9ed5c5822680c00d9eaa322412680";
    public static Bitmap Render(string payload) {
        string path=Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"QRCoder.dll");
        using(var sha=SHA256.Create())using(var file=File.OpenRead(path)) {
            if(BitConverter.ToString(sha.ComputeHash(file)).Replace("-","").ToLowerInvariant()!=Expected)
                throw new InvalidDataException("Reviewed QR renderer unavailable");
        }
        var assembly=Assembly.LoadFrom(path);
        dynamic generator=Activator.CreateInstance(assembly.GetType("QRCoder.QRCodeGenerator",true));
        dynamic data=null,code=null;
        try {
            dynamic level=Enum.Parse(assembly.GetType("QRCoder.QRCodeGenerator+ECCLevel",true),"Q");
            data=generator.CreateQrCode(payload,level);
            code=Activator.CreateInstance(assembly.GetType("QRCoder.QRCode",true),new object[]{data});
            return code.GetGraphic(8);
        } finally {
            if(code!=null)((IDisposable)code).Dispose();
            if(data!=null)((IDisposable)data).Dispose();
            ((IDisposable)generator).Dispose();
        }
    }
}
