// Files-only fixture. Never starts a UI, backend, listener, identity or vendor code.
using System;
using System.IO;
using System.Security.Cryptography;

internal static class DevelopmentDefaultsFixtures {
    static int checks;
    static void Check(bool value,string name){if(!value)throw new Exception(name);checks++;}
    static int Main(string[] args){
        var root=Path.GetFullPath(args[0]);Directory.CreateDirectory(root);
        var config=Path.Combine(root,"development-defaults.json");
        var focus=Path.Combine(root,"focus");Directory.CreateDirectory(focus);
        var deployment=Path.Combine(focus,"deployment.json");
        Check(!DevelopmentDefaults.FocusEnabled(root),"absent config stays off");
        File.WriteAllText(deployment,"public fixture inventory");
        string digest;using(var sha=SHA256.Create())digest=BitConverter.ToString(sha.ComputeHash(File.ReadAllBytes(deployment))).Replace("-","").ToLowerInvariant();
        string valid="{\"version\":1,\"focusEnabled\":true,\"deploymentSha256\":\""+digest+"\"}";
        File.WriteAllText(config,valid);Check(DevelopmentDefaults.FocusEnabled(root),"ordinary launch enables both capabilities for matched configured build");
        File.WriteAllText(deployment,"different inventory");Check(!DevelopmentDefaults.FocusEnabled(root),"changed deployment cannot inherit default");
        File.WriteAllText(deployment,"public fixture inventory");
        File.WriteAllText(config,valid.Replace("true","false"));Check(!DevelopmentDefaults.FocusEnabled(root),"explicit configuration off honored");
        File.WriteAllText(config,valid.Replace("\"version\":1","\"version\":true"));Check(!DevelopmentDefaults.FocusEnabled(root),"wrong field type rejected");
        File.WriteAllText(config,"{");Check(!DevelopmentDefaults.FocusEnabled(root),"malformed configuration safe");
        File.WriteAllText(config,new string(' ',2049));Check(!DevelopmentDefaults.FocusEnabled(root),"bounded configuration");
        File.WriteAllText(config,valid);Check(DevelopmentDefaults.FocusEnabled(root),"valid defaults survive ordinary relaunch reads");
        Console.WriteLine(checks+" development-default checks PASS; files only");return 0;
    }
}
