using System;

public class FirewallRuleFixture {
    public string ApplicationName="C:\\Spatial PC\\runtime\\python.exe";
    public bool Enabled=true;
    public int Direction=1,Action=0,Profiles=2,Protocol=6;
}
internal static class FirewallPolicyTests {
    static void Check(bool value){if(!value)throw new Exception("Firewall block detection failed");}
    static int Main(){
        var rule=new FirewallRuleFixture();string runtime=rule.ApplicationName;
        Check(FirewallPolicy.BlocksRuntime(rule,runtime.ToUpperInvariant()));
        rule.Profiles=7;Check(FirewallPolicy.BlocksRuntime(rule,runtime));
        rule.Profiles=1;Check(!FirewallPolicy.BlocksRuntime(rule,runtime));rule.Profiles=2;
        rule.Enabled=false;Check(!FirewallPolicy.BlocksRuntime(rule,runtime));rule.Enabled=true;
        rule.Action=1;Check(!FirewallPolicy.BlocksRuntime(rule,runtime));rule.Action=0;
        rule.Direction=2;Check(!FirewallPolicy.BlocksRuntime(rule,runtime));rule.Direction=1;
        Check(!FirewallPolicy.BlocksRuntime(rule,runtime+".other"));
        rule.Protocol=17;Check(FirewallPolicy.BlocksRuntime(rule,runtime));
        rule.Protocol=256;Check(FirewallPolicy.BlocksRuntime(rule,runtime));
        rule.Protocol=1;Check(!FirewallPolicy.BlocksRuntime(rule,runtime));
        Console.WriteLine("PASS: program, direction, profile, protocol and explicit block detection; no firewall rules changed");return 0;
    }
}
