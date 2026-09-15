using System;
using System.IO;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

internal static class FirewallPolicy {
    internal sealed class RuleSpec {
        internal string Program,Ports;internal int Protocol;
        internal RuleSpec(string program,int protocol,string ports){Program=program;Protocol=protocol;Ports=ports;}
    }
    static string Runtime { get { return Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"runtime","python.exe")); } }
    internal static RuleSpec[] ProductRules(string root) {
        string python=Path.GetFullPath(Path.Combine(root,"runtime","python.exe")),xr=Path.GetFullPath(Path.Combine(root,"focus","CloudXrService.exe"));
        return new[]{new RuleSpec(python,6,"47990,47991,47994,55000"),new RuleSpec(python,17,"5353"),
            new RuleSpec(xr,6,"48322"),new RuleSpec(xr,17,"47998,47999,48005,48008,48012")};
    }
    static RuleSpec[] Rules {get{return ProductRules(AppDomain.CurrentDomain.BaseDirectory);}}
    static string RuleName(RuleSpec spec) {
        using(var hash=SHA256.Create())return "Spatial PC "+spec.Protocol+" "+BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(spec.Program.ToLowerInvariant()))).Replace("-","").Substring(0,16);
    }
    static dynamic Policy(){return Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FwPolicy2"));}
    internal static bool BlocksRuntime(dynamic rule,string runtime) {
        return String.Equals((string)rule.ApplicationName,runtime,StringComparison.OrdinalIgnoreCase)
            &&(bool)rule.Enabled&&(int)rule.Direction==1&&(int)rule.Action==0&&((int)rule.Profiles&2)!=0
            &&((int)rule.Protocol==6||(int)rule.Protocol==17||(int)rule.Protocol==256);
    }
    internal static string BlockReason() {
        try{foreach(dynamic rule in Policy().Rules)foreach(var spec in Rules)if(File.Exists(spec.Program)&&BlocksRuntime(rule,spec.Program))
            return "Windows Firewall has a block rule for this installation. Ask your Windows administrator to review it before enabling access.";
            return null;
        }catch(Exception){return "Windows Firewall could not be checked. Ask your Windows administrator to review Spatial PC network access.";}
    }
    static bool Matches(dynamic rule,RuleSpec spec) {
        return String.Equals((string)rule.ApplicationName,spec.Program,StringComparison.OrdinalIgnoreCase)
            &&(int)rule.Direction==1&&(int)rule.Action==1&&(bool)rule.Enabled&&(int)rule.Profiles==2
            &&(int)rule.Protocol==spec.Protocol&&(string)rule.LocalPorts==spec.Ports
            &&String.Equals((string)rule.RemoteAddresses,"LocalSubnet",StringComparison.OrdinalIgnoreCase)&&!(bool)rule.EdgeTraversal;
    }
    internal static bool Configured() {
        if(BlockReason()!=null)return false;
        try{dynamic policy=Policy();foreach(var spec in Rules)if(File.Exists(spec.Program)&&!Matches(policy.Rules.Item(RuleName(spec)),spec))return false;return File.Exists(Runtime);}catch(Exception){return false;}
    }
    internal static bool Present() {
        try{dynamic policy=Policy();foreach(var spec in Rules){try{dynamic rule=policy.Rules.Item(RuleName(spec));if(String.Equals((string)rule.ApplicationName,spec.Program,StringComparison.OrdinalIgnoreCase))return true;}catch(Exception e){if(e.HResult!=unchecked((int)0x80070002))throw;}}return false;}catch(Exception){return true;}
    }
    // No supplied paths/ports, wildcard profiles, global enable, or unrelated rule edits.
    internal static int Configure(bool remove) {
        if(!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator))return 5;
        if(!remove&&!File.Exists(Runtime))return 2;
        if(!remove&&BlockReason()!=null)return 6; // Preserve explicit block policy.
        try {
            dynamic policy=Policy();
            foreach(var spec in Rules) {
                if(!remove&&!File.Exists(spec.Program))continue;
                string name=RuleName(spec);dynamic existing=null;
                try{existing=policy.Rules.Item(name);}catch(Exception e){if(e.HResult!=unchecked((int)0x80070002))throw;}
                if(existing!=null) {
                    if(!String.Equals((string)existing.ApplicationName,spec.Program,StringComparison.OrdinalIgnoreCase))return 3;
                    policy.Rules.Remove(name);
                }
                if(remove)continue;
                dynamic rule=Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FWRule"));
                rule.Name=name;rule.Description="Spatial PC: this installation, Private networks, local subnet only.";
                rule.ApplicationName=spec.Program;rule.Protocol=spec.Protocol;rule.LocalPorts=spec.Ports;
                rule.RemoteAddresses="LocalSubnet";rule.Direction=1;rule.Action=1;rule.Profiles=2;
                rule.EdgeTraversal=false;rule.Enabled=true;policy.Rules.Add(rule);
            }
            return remove||Configured()?0:4;
        }catch(Exception){return 4;}
    }
}
