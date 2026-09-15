using System;
class FocusQrTest {
    static void Main(){
        using(var bitmap=FocusQr.Render("{\"token\":\"PUBLIC-FIXTURE-NOT-A-CREDENTIAL\",\"digest\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}")){
            if(bitmap.Width<100||bitmap.Width!=bitmap.Height)throw new Exception("QR generation failed");
        }
        Console.WriteLine("PASS pinned QRCoder public fixture rendered/disposed in memory; no window or file");
    }
}
