using System;
using System.Runtime.InteropServices;
class FocusOutputTest {
    [DllImport("ucrtbase.dll",CallingConvention=CallingConvention.Cdecl)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)] static extern int puts(string message);
    static void Main(){
        using(var output=FocusOutput.PrivatePipe()){
            Console.WriteLine("UNEXPECTED_MANAGED_FIXTURE_OUTPUT");
            puts("UNEXPECTED_NATIVE_FIXTURE_OUTPUT");
            output.WriteLine("PRIVATE_CONTROL_FIXTURE_ONLY");
        }
    }
}
