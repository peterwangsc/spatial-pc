using System;
using System.IO;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

internal static class FirewallPolicy {
    static string Runtime { get { return Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"runtime","python.exe")); } }
    static string RuleName(int protocol) {
        using(var hash=SHA256.Create())return "Spatial PC "+protocol+" "+BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(Runtime.ToLowerInvariant()))).Replace("-","").Substring(0,16);
    }
    static dynamic Policy(){return Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FwPolicy2"));}
    internal static bool BlocksRuntime(dynamic rule,string runtime) {
        return String.Equals((string)rule.ApplicationName,runtime,StringComparison.OrdinalIgnoreCase)
            &&(bool)rule.Enabled&&(int)rule.Direction==1&&(int)rule.Action==0&&((int)rule.Profiles&2)!=0
            &&((int)rule.Protocol==6||(int)rule.Protocol==17||(int)rule.Protocol==256);
    }
    internal static string BlockReason() {
        try{foreach(dynamic rule in Policy().Rules)if(BlocksRuntime(rule,Runtime))
            return "Windows Firewall has a block rule for this installation. Ask your Windows administrator to review it before enabling access.";
            return null;
        }catch(Exception){return "Windows Firewall could not be checked. Ask your Windows administrator to review Spatial PC network access.";}
    }
    static bool Matches(dynamic rule,int protocol) {
        return String.Equals((string)rule.ApplicationName,Runtime,StringComparison.OrdinalIgnoreCase)
            &&(int)rule.Direction==1&&(int)rule.Action==1&&(bool)rule.Enabled&&(int)rule.Profiles==2
            &&(int)rule.Protocol==protocol&&(string)rule.LocalPorts==(protocol==6?"47990,47991":"5353")
            &&String.Equals((string)rule.RemoteAddresses,"LocalSubnet",StringComparison.OrdinalIgnoreCase)&&!(bool)rule.EdgeTraversal;
    }
    internal static bool Configured() {
        if(BlockReason()!=null)return false;
        try{dynamic policy=Policy();foreach(int protocol in new[]{6,17})if(!Matches(policy.Rules.Item(RuleName(protocol)),protocol))return false;return true;}catch(Exception){return false;}
    }
    internal static bool Present() {
        try{dynamic policy=Policy();foreach(int protocol in new[]{6,17}){try{dynamic rule=policy.Rules.Item(RuleName(protocol));if(String.Equals((string)rule.ApplicationName,Runtime,StringComparison.OrdinalIgnoreCase))return true;}catch(Exception e){if(e.HResult!=unchecked((int)0x80070002))throw;}}return false;}catch(Exception){return true;}
    }
    // No supplied paths/ports, wildcard profiles, global enable, or unrelated rule edits.
    internal static int Configure(bool remove) {
        if(!new WindowsPrincipal(WindowsIdentity.GetCurrent()).IsInRole(WindowsBuiltInRole.Administrator))return 5;
        if(!remove&&!File.Exists(Runtime))return 2;
        if(!remove&&BlockReason()!=null)return 6; // Preserve explicit block policy.
        try {
            dynamic policy=Policy();
            foreach(int protocol in new[]{6,17}) {
                string name=RuleName(protocol);dynamic existing=null;
                try{existing=policy.Rules.Item(name);}catch(Exception e){if(e.HResult!=unchecked((int)0x80070002))throw;}
                if(existing!=null) {
                    if(!String.Equals((string)existing.ApplicationName,Runtime,StringComparison.OrdinalIgnoreCase))return 3;
                    policy.Rules.Remove(name);
                }
                if(remove)continue;
                dynamic rule=Activator.CreateInstance(Type.GetTypeFromProgID("HNetCfg.FWRule"));
                rule.Name=name;rule.Description="Spatial PC: this installation, Private networks, local subnet only.";
                rule.ApplicationName=Runtime;rule.Protocol=protocol;rule.LocalPorts=protocol==6?"47990,47991":"5353";
                rule.RemoteAddresses="LocalSubnet";rule.Direction=1;rule.Action=1;rule.Profiles=2;
                rule.EdgeTraversal=false;rule.Enabled=true;policy.Rules.Add(rule);
            }
            return remove||Configured()?0:4;
        }catch(Exception){return 4;}
    }
}
