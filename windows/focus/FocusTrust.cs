using System;
using System.IO;
using System.Text;
internal static class FocusTrust {
    // The6.1.0 ABI returns unsigned char* plus explicit length, not a C string.
    internal static string Token(byte[] bytes,UIntPtr returned){
        ulong length=returned.ToUInt64();
        if(length==0||length>(ulong)bytes.Length)throw new InvalidDataException("Invalid token length");
        int count=(int)length;
        if(bytes[count-1]==0)count--; // Accept one declared terminator, never embedded NUL.
        if(count==0)throw new InvalidDataException("Empty token");
        for(int i=0;i<count;i++)if(bytes[i]<33||bytes[i]>126)throw new InvalidDataException("Unsupported token encoding");
        return Encoding.ASCII.GetString(bytes,0,count);
    }
}
