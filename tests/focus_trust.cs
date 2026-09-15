using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using FoveatedStreaming.WindowsSample;
class FocusTrustTest {
    static void Bad(byte[] bytes,int count){try{FocusTrust.Token(bytes,(UIntPtr)count);throw new Exception("Accepted invalid token");}catch(InvalidDataException){}}
    static void Main(){
        var plain=Encoding.ASCII.GetBytes("public-fixture");
        if(FocusTrust.Token(plain,(UIntPtr)plain.Length)!="public-fixture")throw new Exception();
        var terminated=Encoding.ASCII.GetBytes("public-fixture\0");
        if(FocusTrust.Token(terminated,(UIntPtr)terminated.Length)!="public-fixture")throw new Exception();
        Bad(plain,0);Bad(plain,100);Bad(new byte[]{0},1);Bad(new byte[]{65,0,66},3);Bad(new byte[]{255},1);
        var type=typeof(NvCloudXR.nv_service_status_t);
        if(Marshal.SizeOf(type)!=16656||Marshal.OffsetOf(type,"openxr_log_file_path_bytes").ToInt32()!=3||Marshal.OffsetOf(type,"openxr_log_file_path_length").ToInt32()!=264||Marshal.OffsetOf(type,"reserved").ToInt32()!=272)throw new Exception("Managed ABI mismatch");
        Console.WriteLine("PASS managed status ABI and7 public token length/encoding cases; no DLL loaded");
    }
}
