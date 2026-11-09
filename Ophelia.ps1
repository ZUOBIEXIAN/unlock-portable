<#
.SYNOPSIS
Ophelia: standalone Windows PowerShell 5.1 launcher and LAN web service.
.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Ophelia.ps1
.NOTES
The launcher starts no listener until Start is clicked. Select an automatically
discovered IPv4, configure HTTPS with explicit administrator approval, export
the public certificate, and have authorized clients trust it. Default port 443.
Use desktop Edge/Chrome; the user must select and grant access to each file or
folder. Browser API restrictions and endpoint encryption policies still apply.
Minimize/close hides the launcher to tray. Tray Exit actually stops the server.
Detection sends only candidate headers; decryption uploads each selected file
then verifies the response and the unchanged original before browser writeback.
Logs: %LOCALAPPDATA%\Ophelia\logs. Temporary job copies are removed after use;
a crash or forced kill may leave an isolated session folder under Ophelia\temp.
No Node.js, dependencies, external page assets, existing scripts, DNS changes,
or remote code execution are required. Name aliases require LAN name resolution.
-Headless -HttpLocalTest is restricted to 127.0.0.1 and is for local tests only.
#>
param(
    [switch]$Headless,
    [string]$BindAddress = '127.0.0.1',
    [ValidateRange(1,65535)][int]$Port = 443,
    [ValidateRange(1,2048)][int]$MaxFileMB = 128,
    [ValidateRange(1,8)][int]$Workers = 2,
    [string]$Password,
    [switch]$HttpLocalTest,
    [switch]$ConfigureHttps,
    [string]$StateDirectory,
    [string]$TargetUser,
    [switch]$LoadOnly,
    [switch]$GuiProcess
)

# Standalone LAN host. Existing CLI/install scripts are not loaded or changed.
$ErrorActionPreference = 'Stop'
if (-not $StateDirectory) { $StateDirectory = Join-Path $env:LOCALAPPDATA 'Ophelia' }
$StateDirectory = [IO.Path]::GetFullPath($StateDirectory)
$ServerScriptPath = $PSCommandPath

function Get-ServerIPv4 {
    $result = New-Object 'System.Collections.Generic.List[object]'
    $result.Add([pscustomobject]@{Address='127.0.0.1'; Display='127.0.0.1 — 仅本机'})
    $seen = @{'127.0.0.1'=$true}
    foreach ($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($adapter.OperationalStatus -ne [Net.NetworkInformation.OperationalStatus]::Up) { continue }
        foreach ($unicast in $adapter.GetIPProperties().UnicastAddresses) {
            $ip = $unicast.Address
            if ($ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or [Net.IPAddress]::IsLoopback($ip)) { continue }
            $address = $ip.ToString()
            if ($address.StartsWith('169.254.') -or $seen.ContainsKey($address)) { continue }
            $seen[$address] = $true
            $result.Add([pscustomobject]@{Address=$address; Display=($address + ' — ' + $adapter.Name)})
        }
    }
    return $result.ToArray()
}

function New-ServerPassword {
    $bytes = New-Object byte[] 24
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function Get-HttpsStatePath([string]$Address, [int]$ListenPort) {
    Join-Path $StateDirectory ('https-' + $Address.Replace('.','-') + '-' + $ListenPort + '.json')
}

function Set-ServerHttps {
    if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'HTTPS 配置需要管理员权限；请使用启动器中的配置按钮。'
    }
    $addresses = @(Get-ServerIPv4 | ForEach-Object Address)
    if ($BindAddress -notin $addresses) { throw '所选 IP 不属于当前可用本机 IPv4，请刷新 IP 列表。' }
    if (-not $TargetUser) { $TargetUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
    $sid = (New-Object Security.Principal.NTAccount $TargetUser).Translate([Security.Principal.SecurityIdentifier]).Value
    [IO.Directory]::CreateDirectory($StateDirectory) | Out-Null
    $statePath = Get-HttpsStatePath $BindAddress $Port
    $previous = $null
    if (Test-Path -LiteralPath $statePath) { $previous = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    $appId = '{88E3D652-0B37-48F8-983A-9B7025C298C4}'
    $ipPort = $BindAddress + ':' + $Port
    $url = 'https://' + $BindAddress + ':' + $Port + '/'
    $ssl = (& netsh.exe http show sslcert "ipport=$ipPort" 2>&1 | Out-String)
    $sslExists = $LASTEXITCODE -eq 0
    if ($sslExists -and $ssl -notmatch [regex]::Escape($appId)) { throw '该 IP/端口已有其他 HTTPS 绑定。请换一个端口；不会覆盖其他服务。' }
    $urls = @($url)
    if ($BindAddress -ne '127.0.0.1') {
        $urls += ('https://ophelia:' + $Port + '/')
        $urls += ('https://unlock:' + $Port + '/')
        $urls += ('https://' + $env:COMPUTERNAME.ToLowerInvariant() + ':' + $Port + '/')
        $urls = @($urls | Select-Object -Unique)
    }
    $newReservations = @()
    foreach ($reservedUrl in $urls) {
        $acl = (& netsh.exe http show urlacl "url=$reservedUrl" 2>&1 | Out-String)
        $aclExitCode = $LASTEXITCODE
        # netsh returns 0 with an empty heading when the URL is not reserved.
        # Require an actual URL row, independently of the localized heading.
        $aclExists = $aclExitCode -eq 0 -and $acl -match ('(?im)^\s*[^\r\n]*?:\s*' + [regex]::Escape($reservedUrl) + '\s*$')
        if ($aclExitCode -ne 0) { throw ("查询 URL 监听权限失败：$reservedUrl`r`n$acl") }
        if ($aclExists -and (-not $previous -or $previous.AppId -ne $appId -or $previous.UserSid -ne $sid)) {
            throw ("该地址已有无法确认归属的 URL 保留：$reservedUrl 。请换端口；不会修改其他服务权限。")
        }
        if (-not $aclExists) { $newReservations += $reservedUrl }
    }
    $cert = $null
    if ($previous -and $previous.Thumbprint) {
        $candidate = Get-Item -LiteralPath ('Cert:\LocalMachine\My\' + $previous.Thumbprint) -ErrorAction SilentlyContinue
        if ($candidate -and $candidate.HasPrivateKey -and $candidate.NotAfter -gt (Get-Date).AddDays(30) -and ($previous.Addresses -join ',') -eq ($addresses -join ',')) { $cert = $candidate }
    }
    if (-not $cert) {
        $san = '2.5.29.17={text}DNS=localhost&DNS=ophelia&DNS=unlock&DNS=' + $env:COMPUTERNAME
        foreach ($address in $addresses) { $san += '&IPAddress=' + $address }
        $cert = New-SelfSignedCertificate -Type Custom -Subject ('CN=' + $env:COMPUTERNAME) -CertStoreLocation 'Cert:\LocalMachine\My' -KeyAlgorithm RSA -KeyLength 2048 -HashAlgorithm SHA256 -KeyExportPolicy NonExportable -KeyUsage DigitalSignature,KeyEncipherment -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.1', $san) -NotAfter (Get-Date).AddYears(1) -FriendlyName ('Ophelia HTTPS ' + $ipPort)
    }
    foreach ($reservedUrl in $newReservations) {
        & netsh.exe http add urlacl "url=$reservedUrl" "sddl=D:(A;;GX;;;$sid)"
        if ($LASTEXITCODE -ne 0) { throw '添加 URL 监听权限失败。' }
    }
    if ($sslExists) { & netsh.exe http update sslcert "ipport=$ipPort" "certhash=$($cert.Thumbprint)" "appid=$appId" 'certstorename=MY' }
    else { & netsh.exe http add sslcert "ipport=$ipPort" "certhash=$($cert.Thumbprint)" "appid=$appId" 'certstorename=MY' }
    if ($LASTEXITCODE -ne 0) { throw 'HTTPS 证书绑定失败。' }
    if ($BindAddress -ne '127.0.0.1') {
        $ruleName = 'Ophelia-HTTPS-' + $BindAddress.Replace('.','-') + '-' + $Port
        if (-not (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name $ruleName -DisplayName ('Ophelia HTTPS ' + $ipPort) -Description 'Ophelia: Private network / local subnet only' -Direction Inbound -Action Allow -Protocol TCP -LocalAddress $BindAddress -LocalPort $Port -RemoteAddress LocalSubnet -Profile Private | Out-Null
        }
    }
    $publicCert = Join-Path $StateDirectory ('ophelia-' + $BindAddress.Replace('.','-') + '-' + $Port + '.cer')
    [IO.File]::WriteAllBytes($publicCert, $cert.Export([Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    @{AppId=$appId; UserSid=$sid; Address=$BindAddress; Port=$Port; Thumbprint=$cert.Thumbprint; Addresses=$addresses; PublicCertificate=$publicCert; Url=$url; ReservedUrls=$urls} |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statePath -Encoding UTF8
    Write-Host "HTTPS 已配置：$url"
    Write-Host "公钥证书：$publicCert"
    Write-Host '客户端需将此公钥证书导入当前用户的“受信任的根证书颁发机构”，或改用受组织信任的证书。不要关闭浏览器安全检查。'
}

if ($ConfigureHttps) {
    try { Set-ServerHttps; exit 0 }
    catch {
        [IO.Directory]::CreateDirectory($StateDirectory) | Out-Null
        [IO.File]::AppendAllText((Join-Path $StateDirectory 'https-setup-error.log'), ((Get-Date).ToString('s') + ' ' + $_.Exception.Message + [Environment]::NewLine))
        Write-Error $_.Exception.Message
        exit 1
    }
}

if (-not ('UnlockLan.Server' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Collections.Concurrent;
using System.Security.Cryptography;

namespace UnlockLan {
    public sealed class Header {
        public string Kind;
        public string Reason;
        public long FileBytes;
    }
    public sealed class Decoded {
        public long Bytes;
        public string Hash;
    }
    public static class Crypto {
        static byte CRCStep(byte a, byte b) {
            int n = a ^ b;
            for (int i=0;i<8;i++) n=(n>>1)^((n&1)!=0?0xe0:0);
            return (byte)n;
        }
        public static Header Inspect(byte[] h, long size) {
            Header r=new Header {Kind="Plain",Reason="未发现加密包头",FileBytes=size};
            if(h.Length<2||(h[0]&0xf0)!=0x80||h[1]!=0x7d) return r;
            if(h.Length<26||size<4096) {r.Kind="Invalid";r.Reason="加密头不完整";return r;}
            if(h[0]!=0x89||h[2]!=0x1c) {r.Kind="Unsupported";r.Reason=String.Format("不支持的加密版本或模式：0x{0:X2} / 0x{1:X2}",h[0],h[2]);return r;}
            if(h.Length<512) {r.Kind="Invalid";r.Reason="加密头不足 512 字节";return r;}
            byte c=255;
            for(int i=8;i<12;i++) c=CRCStep(c,h[i]);
            for(int i=28;i<512;i++) if(i!=46)c=CRCStep(c,h[i]);
            if(h[46]!=(byte)(255-c)) {r.Kind="Invalid";r.Reason="头部 CRC 校验失败";return r;}
            r.Kind="Supported";r.Reason="已加密，可处理";return r;
        }
        static byte[] Part(byte[] b,int start,int count) {byte[] r=new byte[count];Buffer.BlockCopy(b,start,r,0,count);return r;}
        static byte[] RC4(byte[] key,byte[] b) {
            byte[] s=new byte[256];for(int n=0;n<256;n++)s[n]=(byte)n;
            int j=0;for(int n=0;n<256;n++){j=(j+s[n]+key[n%key.Length])&255;byte t=s[n];s[n]=s[j];s[j]=t;}
            byte[] r=new byte[b.Length];int i=0;j=0;
            for(int n=0;n<b.Length;n++){i=(i+1)&255;j=(j+s[i])&255;byte t=s[i];s[i]=s[j];s[j]=t;r[n]=(byte)(b[n]^s[(s[i]+s[j])&255]);}
            Array.Clear(s,0,s.Length);return r;
        }
        static byte[] Stream(byte[] h) {
            byte[] p=Part(h,8,4),check=RC4(p,Part(h,12,8));
            byte[] selected=new byte[]{check[6],check[0],check[5]},repeat=new byte[16];
            for(int i=0;i<16;i++)repeat[i]=p[i%4];
            byte[] first=RC4(selected,repeat);Buffer.BlockCopy(selected,0,first,0,3);
            byte[] key=RC4(p,first),result=RC4(key,new byte[512]);
            Array.Clear(key,0,key.Length);Array.Clear(check,0,check.Length);Array.Clear(selected,0,selected.Length);Array.Clear(first,0,first.Length);return result;
        }
        public static string Hex(byte[] b) {return BitConverter.ToString(b).Replace("-","").ToLowerInvariant();}
        public static Decoded Decrypt(string source,string destination) {
            byte[] key=null;
            try {
                using(FileStream input=new FileStream(source,FileMode.Open,FileAccess.Read,FileShare.Read)) {
                    byte[] h=new byte[512];int count=0,n;
                    while(count<h.Length&&(n=input.Read(h,count,h.Length-count))>0)count+=n;
                    if(count!=512||Inspect(h,input.Length).Kind!="Supported")throw new InvalidDataException("不支持或损坏的加密头");
                    key=Stream(h);input.Position=4096;
                    long done=0;string digest;
                    using(SHA256 sha=SHA256.Create())
                    using(FileStream output=new FileStream(destination,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
                        byte[] buffer=new byte[1024*1024];
                        while((n=input.Read(buffer,0,buffer.Length))>0){for(int i=0;i<n;i++)buffer[i]^=key[(int)((done+i)&511)];sha.TransformBlock(buffer,0,n,buffer,0);output.Write(buffer,0,n);done+=n;}
                        sha.TransformFinalBlock(new byte[0],0,0);digest=Hex(sha.Hash);output.Flush(true);
                        if(done!=input.Length-4096)throw new IOException("正文长度不符");
                    }
                    using(SHA256 sha=SHA256.Create())using(FileStream verify=File.OpenRead(destination)) {
                        if(verify.Length!=done||Hex(sha.ComputeHash(verify))!=digest)throw new IOException("临时结果核验失败");
                    }
                    return new Decoded{Bytes=done,Hash=digest};
                }
            }finally{if(key!=null)Array.Clear(key,0,key.Length);}
        }
    }

    public sealed class Server : IDisposable {
        readonly string html,address,password,dataRoot;
        readonly bool tls,localOnly;
        readonly int port;
        readonly long maxBytes;
        readonly SemaphoreSlim slots;
        readonly object logLock=new object();
        readonly ConcurrentDictionary<string,HttpListenerContext> contexts=new ConcurrentDictionary<string,HttpListenerContext>();
        readonly ConcurrentQueue<string> logs=new ConcurrentQueue<string>();
        HttpListener listener;
        Thread acceptThread;
        volatile bool running;
        string session;
        int active,ok,skipped,failed;
        public bool Running {get{return running;}}
        public int Active {get{return active;}}
        public int Succeeded {get{return ok;}}
        public int Skipped {get{return skipped;}}
        public int Failed {get{return failed;}}
        public long MaxBytes {get{return maxBytes;}}
        public string Url {get{return (tls?"https":"http")+"://"+address+":"+port+"/";}}
        public string LogDirectory {get{return Path.Combine(dataRoot,"logs");}}
        public Server(string page,string bind,int listenPort,bool useTls,string secret,long limit,int workers,string root) {
            IPAddress ip;if(!IPAddress.TryParse(bind,out ip)||ip.AddressFamily!=System.Net.Sockets.AddressFamily.InterNetwork)throw new ArgumentException("Invalid IPv4");
            if(secret==null||secret.Length<12||secret.Length>256)throw new ArgumentException("访问口令至少 12 位，最多 256 位");
            foreach(char ch in secret)if(ch<33||ch>126)throw new ArgumentException("口令请使用英文字母、数字和符号，不含空白或中文");
            if(limit<1||workers<1||workers>8)throw new ArgumentException("Invalid limits");
            localOnly=IPAddress.IsLoopback(ip);if(!useTls&&!localOnly)throw new ArgumentException("局域网必须使用 HTTPS");
            html=page;address=bind;port=listenPort;tls=useTls;password=secret;maxBytes=limit;dataRoot=Path.GetFullPath(root);slots=new SemaphoreSlim(workers,workers);
        }
        static string Q(string value) {
            if(value==null)return "null";StringBuilder b=new StringBuilder("\"");
            foreach(char c in value){if(c=='"')b.Append("\\\"");else if(c=='\\')b.Append("\\\\");else if(c=='\n')b.Append("\\n");else if(c=='\r')b.Append("\\r");else if(c=='\t')b.Append("\\t");else if(c<32)b.Append("\\u"+((int)c).ToString("x4"));else b.Append(c);}return b.Append('"').ToString();
        }
        static string SafeLabel(string value) {
            if(value==null)return "file";StringBuilder b=new StringBuilder();foreach(char c in value){if(!char.IsControl(c))b.Append(c);if(b.Length>=180)break;}return b.ToString();
        }
        void Log(string level,string message) {
            string line=DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss")+" ["+level+"] "+message;
            lock(logLock){Directory.CreateDirectory(LogDirectory);File.AppendAllText(Path.Combine(LogDirectory,DateTime.Now.ToString("yyyy-MM-dd")+".log"),line+Environment.NewLine,new UTF8Encoding(false));}
            logs.Enqueue(line);string ignored;while(logs.Count>1000)logs.TryDequeue(out ignored);
        }
        public string[] DrainLogs(){System.Collections.Generic.List<string> r=new System.Collections.Generic.List<string>();string s;while(logs.TryDequeue(out s))r.Add(s);return r.ToArray();}
        public void Start() {
            if(running)throw new InvalidOperationException("Already running");
            Directory.CreateDirectory(Path.Combine(dataRoot,"temp"));
            session=Path.Combine(dataRoot,"temp","session-"+Guid.NewGuid().ToString("N"));Directory.CreateDirectory(session);
            listener=new HttpListener();listener.Prefixes.Add(Url);
            if(tls&&!localOnly){var aliases=new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase){"ophelia","unlock",Environment.MachineName};foreach(string alias in aliases)listener.Prefixes.Add("https://"+alias.ToLowerInvariant()+":"+port+"/");}
            try{listener.TimeoutManager.EntityBody=TimeSpan.FromMinutes(5);listener.TimeoutManager.IdleConnection=TimeSpan.FromSeconds(30);listener.TimeoutManager.HeaderWait=TimeSpan.FromSeconds(20);listener.Start();}
            catch{listener.Close();Directory.Delete(session);throw;}
            running=true;try{Log("INFO","START "+Url+" maxBytes="+maxBytes);acceptThread=new Thread(Accept);acceptThread.IsBackground=true;acceptThread.Start();}catch{Stop();throw;}
        }
        void Accept() {
            while(running){HttpListenerContext c;try{c=listener.GetContext();}catch(Exception ex){if(running){try{Log("ERROR","Listener stopped: "+ex.GetType().Name);}catch{}Stop();}break;}
                if(!running){try{c.Response.Abort();}catch{}break;}
                if(!slots.Wait(0)){try{c.Response.Headers["Retry-After"]="2";Json(c,429,"{\"error\":\"服务器忙，请稍后重试\"}");}catch{}continue;}
                string id=Guid.NewGuid().ToString("N");contexts[id]=c;Interlocked.Increment(ref active);
                ThreadPool.QueueUserWorkItem(delegate{try{if(running)Handle(c,id);else c.Response.Abort();}catch(Exception ex){if(running){Interlocked.Increment(ref failed);try{Log("ERROR",id+" "+ex.GetType().Name+": "+ex.Message);}catch{}}try{Json(c,500,"{\"error\":\"服务端处理失败，原文件未写回\"}");}catch{}}
                    finally{HttpListenerContext ignored;contexts.TryRemove(id,out ignored);try{c.Response.Close();}catch{}Interlocked.Decrement(ref active);slots.Release();TryRemoveSession();}});
            }
        }
        void Common(HttpListenerResponse r) {
            r.KeepAlive=false;r.Headers["Cache-Control"]="no-store";r.Headers["X-Content-Type-Options"]="nosniff";r.Headers["Referrer-Policy"]="no-referrer";r.Headers["Cross-Origin-Opener-Policy"]="same-origin";
        }
        void Json(HttpListenerContext c,int status,string json) {
            byte[] b=Encoding.UTF8.GetBytes(json);Common(c.Response);c.Response.StatusCode=status;c.Response.ContentType="application/json; charset=utf-8";c.Response.ContentLength64=b.Length;c.Response.OutputStream.Write(b,0,b.Length);c.Response.Close();
        }
        bool Authorized(HttpListenerRequest r) {
            string supplied=r.Headers["Authorization"]??"";string expected="Bearer "+password;
            byte[] a=Encoding.UTF8.GetBytes(supplied),b=Encoding.UTF8.GetBytes(expected);int mismatch=a.Length^b.Length;
            for(int i=0;i<b.Length;i++)mismatch|=(i<a.Length?a[i]:0)^b[i];return mismatch==0;
        }
        bool SameOrigin(HttpListenerRequest r) {
            Uri origin;return Uri.TryCreate(r.Headers["Origin"],UriKind.Absolute,out origin)&&origin.Scheme==r.Url.Scheme&&String.Equals(origin.Authority,r.Url.Authority,StringComparison.OrdinalIgnoreCase);
        }
        void Handle(HttpListenerContext c,string id) {
            HttpListenerRequest r=c.Request;
            if(localOnly&&!IPAddress.IsLoopback(r.RemoteEndPoint.Address)){Json(c,403,"{\"error\":\"仅允许本机访问\"}");return;}
            if(r.HttpMethod=="GET"&&r.Url.AbsolutePath=="/") {
                string nonce=Guid.NewGuid().ToString("N");string page=html.Replace("__NONCE__",nonce);
                byte[] b=Encoding.UTF8.GetBytes(page);Common(c.Response);c.Response.Headers["Content-Security-Policy"]="default-src 'none'; script-src 'nonce-"+nonce+"'; style-src 'nonce-"+nonce+"'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'; object-src 'none'";
                c.Response.ContentType="text/html; charset=utf-8";c.Response.ContentLength64=b.Length;c.Response.OutputStream.Write(b,0,b.Length);c.Response.Close();return;
            }
            if(r.HttpMethod!="POST"||!r.Url.AbsolutePath.StartsWith("/api/",StringComparison.Ordinal)){Json(c,404,"{\"error\":\"Not found\"}");return;}
            if(!Authorized(r)){Json(c,401,"{\"error\":\"访问口令不正确\"}");return;}
            if(!SameOrigin(r)){Json(c,403,"{\"error\":\"跨站请求已拒绝\"}");return;}
            if(r.Url.AbsolutePath=="/api/session") {Json(c,200,"{\"maxFileBytes\":"+maxBytes+",\"name\":\"Ophelia\",\"https\":"+(tls?"true":"false")+"}");return;}
            if(r.ContentLength64<0){Json(c,411,"{\"error\":\"需要明确的请求长度\"}");return;}
            if(r.Url.AbsolutePath=="/api/inspect") {
                long total;if(!Int64.TryParse(r.Headers["X-File-Length"],out total)||total<0||r.ContentLength64>512||total<r.ContentLength64){Json(c,400,"{\"error\":\"无效检测参数\"}");return;}
                byte[] h=new byte[(int)r.ContentLength64];int count=0,n;while(count<h.Length&&(n=r.InputStream.Read(h,count,h.Length-count))>0)count+=n;
                if(count!=h.Length){Json(c,400,"{\"error\":\"检测请求不完整\"}");return;}
                Header info=Crypto.Inspect(h,total);Log("INFO",id+" INSPECT "+info.Kind+" remote="+r.RemoteEndPoint.Address);Json(c,200,"{\"kind\":"+Q(info.Kind)+",\"message\":"+Q(info.Reason)+"}");return;
            }
            if(r.Url.AbsolutePath!="/api/decrypt"){Json(c,404,"{\"error\":\"Not found\"}");return;}
            if(r.ContentLength64>maxBytes){Json(c,413,"{\"error\":\"超过服务端单文件大小限制\"}");return;}
            string expectedHash=r.Headers["X-Content-SHA256"]??"";
            if(!System.Text.RegularExpressions.Regex.IsMatch(expectedHash,"\\A[0-9a-fA-F]{64}\\z")){Json(c,400,"{\"error\":\"缺少上传 SHA256\"}");return;}
            string label="file";try{label=SafeLabel(Encoding.UTF8.GetString(Convert.FromBase64String(r.Headers["X-File-Label"]??"")));}catch{}
            string job=Path.Combine(session,id);Directory.CreateDirectory(job);string input=Path.Combine(job,"input.bin"),output=Path.Combine(job,"output.bin");
            try {
                long received=0;string inputHash;
                using(SHA256 sha=SHA256.Create())using(FileStream f=new FileStream(input,FileMode.CreateNew,FileAccess.Write,FileShare.None)) {
                    byte[] buffer=new byte[1024*1024];int n;while((n=r.InputStream.Read(buffer,0,buffer.Length))>0){received+=n;if(received>maxBytes||received>r.ContentLength64)throw new InvalidDataException("上传长度超限");sha.TransformBlock(buffer,0,n,buffer,0);f.Write(buffer,0,n);}
                    sha.TransformFinalBlock(new byte[0],0,0);inputHash=Crypto.Hex(sha.Hash);f.Flush(true);
                }
                if(received!=r.ContentLength64||!String.Equals(inputHash,expectedHash,StringComparison.OrdinalIgnoreCase)){Json(c,400,"{\"error\":\"上传长度或 SHA256 不一致\"}");return;}
                byte[] prefix=new byte[Math.Min(512,(int)Math.Min(received,512))];using(FileStream f=File.OpenRead(input)){int count=0,n;while(count<prefix.Length&&(n=f.Read(prefix,count,prefix.Length-count))>0)count+=n;}
                Header state=Crypto.Inspect(prefix,received);
                if(state.Kind=="Plain"){Interlocked.Increment(ref skipped);Common(c.Response);c.Response.StatusCode=204;c.Response.Close();return;}
                if(state.Kind!="Supported"){Interlocked.Increment(ref failed);Log("WARN",id+" "+label+" "+state.Kind);Json(c,422,"{\"error\":"+Q(state.Reason)+"}");return;}
                Decoded decoded=Crypto.Decrypt(input,output);
                Common(c.Response);c.Response.ContentType="application/octet-stream";c.Response.Headers["X-Plain-SHA256"]=decoded.Hash;c.Response.ContentLength64=decoded.Bytes;
                using(FileStream f=File.OpenRead(output)){f.CopyTo(c.Response.OutputStream,1024*1024);}c.Response.Close();
                Interlocked.Increment(ref ok);Log("INFO",id+" DECRYPTED "+label+" bytes="+decoded.Bytes+" remote="+r.RemoteEndPoint.Address);
            }finally{
                // Only our random job directory is touched; uploads are never unpacked.
                try{foreach(string f in Directory.GetFiles(job)){File.Delete(f);}Directory.Delete(job,false);}catch(Exception ex){Log("WARN",id+" temporary cleanup failed: "+ex.GetType().Name);}
            }
        }
        void TryRemoveSession(){if(running||active!=0||String.IsNullOrEmpty(session))return;try{Directory.Delete(session,false);}catch{}}
        public void Stop(){if(!running)return;running=false;try{listener.Stop();listener.Close();}catch{}foreach(var pair in contexts){try{pair.Value.Request.InputStream.Close();pair.Value.Response.Abort();}catch{}}try{Log("INFO","STOP");}catch{}TryRemoveSession();}
        public void Dispose(){Stop();}
    }
}
'@
}

$ServerPage = @'
<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Ophelia</title>
<style nonce="__NONCE__">
:root{font-family:Segoe UI,Microsoft YaHei,sans-serif;color:#18233b;background:#f2f5fa;font-size:14px}*{box-sizing:border-box}body{margin:0}header{background:#101e36;color:white;padding:24px max(24px,calc((100vw - 1100px)/2));display:flex;justify-content:space-between;align-items:center}header h1{font-size:24px;margin:0 0 5px;letter-spacing:1px}header p{margin:0;color:#aebed7}.pill{border:1px solid #426083;border-radius:20px;padding:6px 12px;font-size:12px}main{max-width:1100px;margin:28px auto;padding:0 20px}.card{background:white;border:1px solid #e0e7f0;border-radius:14px;padding:24px;margin-bottom:20px;box-shadow:0 6px 24px #20345006}h2{font-size:17px;margin:0 0 14px}.row{display:flex;gap:12px;align-items:center;flex-wrap:wrap}input[type=password]{flex:1;min-width:180px;border:1px solid #cbd5e3;border-radius:8px;padding:11px;font-size:15px}button{cursor:pointer;border:0;border-radius:8px;padding:11px 18px;background:#285cd7;color:white;font:inherit;font-weight:600}button:hover{background:#1749bd}button:disabled{opacity:.45;cursor:not-allowed}.secondary{background:#eaf0fc;color:#244c98}.secondary:hover{background:#dce7fa}.danger{background:#fff0ee;color:#ac3126}.danger:hover{background:#ffe0dc}.muted{color:#718099;font-size:13px;line-height:1.7}.notice{background:#eef4ff;border-left:3px solid #4678e0;padding:12px 16px;line-height:1.75;border-radius:4px;margin-top:16px}.warning{color:#ac3126;background:#fff2ef;border-color:#e27262}.modes{display:flex;gap:24px;margin-bottom:20px;flex-wrap:wrap}.modes label{display:flex;gap:8px;align-items:center;cursor:pointer}.actions button{min-width:160px;padding:16px 22px}.actions .danger{min-width:auto}progress{width:100%;height:12px;accent-color:#285cd7;margin:18px 0 10px}.stats{display:grid;grid-template-columns:repeat(5,1fr);gap:12px;margin-top:20px}.stat{padding:15px;background:#f6f8fc;border-radius:10px}.stat b{display:block;font-size:25px;margin-bottom:4px}.stat span{color:#718099;font-size:12px}.toolbar{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px}select{padding:7px;border-radius:6px;border:1px solid #d5ddea}table{border-collapse:collapse;width:100%;table-layout:fixed}th,td{text-align:left;border-bottom:1px solid #edf0f5;padding:11px 10px;vertical-align:top;word-break:break-word}th{font-size:12px;color:#718099}th:first-child{width:38%}th:nth-child(2){width:16%}.table-wrap{max-height:440px;overflow:auto}.status{display:inline-block;border-radius:5px;padding:3px 7px;font-size:12px;background:#eef2f8;color:#48607f}.good{background:#e7f7ed;color:#187143}.bad{background:#fff0ed;color:#ab352b}.info{background:#eaf1ff;color:#285cd7}#message{min-height:20px;margin-top:12px;line-height:1.6}footer{padding:0 0 24px;text-align:center;color:#7b879c;font-size:12px}#empty{text-align:center;padding:30px;color:#8793a7}@media(max-width:650px){.stats{grid-template-columns:repeat(2,1fr)}.card{padding:18px}header{padding:20px}.pill{display:none}.actions button{min-width:120px}th:first-child{width:34%}}
.note-gap{margin-top:12px}.toolbar h2{margin:0}
</style></head><body>
<header><div><h1>Ophelia</h1><p>让文件回到可用的样子</p></div><span class="pill" id="connection">尚未连接</span></header>
<main>
<section class="card"><h2>01 · 连接服务</h2><form id="loginForm" class="row"><input id="password" type="password" autocomplete="off" placeholder="输入管理员提供的访问口令" aria-label="访问口令" maxlength="256"><button id="login" type="submit">连接</button></form><div id="connectionInfo" class="muted">口令仅保留在本页内存，不写入网址或浏览器存储。</div></section>
<section class="card"><h2>02 · 选择操作和本地文件</h2><div class="modes"><label><input name="mode" type="radio" value="decrypt" checked>解密并原位写回</label><label><input name="mode" type="radio" value="inspect">仅检测是否加密（不修改）</label></div>
<div class="row actions"><button id="chooseFile" disabled>选择一个文件</button><button id="chooseFolder" class="secondary" disabled>选择文件夹</button><button id="cancel" class="danger" disabled>停止本次处理</button></div>
<div class="notice" id="capability">请选择 Edge / Chrome，并通过可信 HTTPS 访问。文件和文件夹必须由你主动选择并授权。</div>
<div class="muted note-gap">不限制文件后缀；普通文件跳过，无法解密的文件标记失败。仅检测时只发送疑似加密文件的前 512 字节；解密时会上传完整文件，核验结果后由浏览器写回。没有拖拽或下载功能。服务端不执行任何上传文件。</div>
<progress id="progress" max="1" value="0"></progress><div id="phase" class="muted">等待选择</div><div id="message" role="status"></div>
<div class="stats"><div class="stat"><b id="total">0</b><span>总文件数</span></div><div class="stat"><b id="encrypted">0</b><span>检测为可解密</span></div><div class="stat"><b id="written">0</b><span>已原位写回</span></div><div class="stat"><b id="skipped">0</b><span>未加密 / 跳过</span></div><div class="stat"><b id="failed">0</b><span>失败</span></div></div>
</section>
<section class="card"><div class="toolbar"><h2>03 · 本次处理结果</h2><div class="row"><select id="filter" aria-label="结果筛选"><option value="all">全部结果</option><option value="failed">仅失败</option></select><button id="copyFailures" class="secondary">复制失败清单</button></div></div><div class="table-wrap"><table><thead><tr><th>文件 / 相对路径</th><th>状态</th><th>说明</th></tr></thead><tbody id="results"></tbody></table><div id="empty">暂无处理结果</div></div><div class="muted" id="rowLimit">最多显示最近 500 条；失败清单可复制。</div></section>
</main><footer>请事先备份重要资料 · 文件系统权限和终端加密策略仍然适用 · 不支持的加密版本不会强行写回</footer>
<script nonce="__NONCE__">
'use strict';
const $=id=>document.getElementById(id);
const state={token:'',ready:false,busy:false,cancel:false,writing:false,xhr:null,maxBytes:0,rows:[],stats:{total:0,encrypted:0,written:0,skipped:0,failed:0}};
const capable=window.isSecureContext&&typeof window.showOpenFilePicker==='function'&&typeof window.showDirectoryPicker==='function'&&!!window.crypto?.subtle;
function message(text,error=false){$('message').textContent=text;$('message').style.color=error?'#ac3126':'#285481';}
function controls(){const enabled=state.ready&&capable&&!state.busy;$('chooseFile').disabled=!enabled;$('chooseFolder').disabled=!enabled;$('login').disabled=state.busy;$('cancel').disabled=!state.busy||state.writing;document.querySelectorAll('input[name=mode]').forEach(x=>x.disabled=state.busy);}
function stats(){for(const key of Object.keys(state.stats))$(key).textContent=state.stats[key];}
function render(){const failedOnly=$('filter').value==='failed';let rows=(failedOnly?state.rows.filter(r=>r.failed):state.rows).slice(-500);$('results').replaceChildren();for(const r of rows){const tr=document.createElement('tr');const a=document.createElement('td');a.textContent=r.label;const b=document.createElement('td');const badge=document.createElement('span');badge.className='status '+(r.failed?'bad':r.written?'good':r.encrypted?'info':'');badge.textContent=r.status;b.append(badge);const c=document.createElement('td');c.textContent=r.detail;tr.append(a,b,c);$('results').append(tr);}$('empty').hidden=rows.length>0;}
let renderPending=false;function result(label,status,detail,extra={}){state.rows.push({label,status,detail,...extra});if(!renderPending){renderPending=true;requestAnimationFrame(()=>{renderPending=false;render();});}}
function stopped(){if(state.cancel)throw new DOMException('已停止本次处理','AbortError');}
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));
const bytes=n=>n>=1048576?(n/1048576).toFixed(1)+' MB':n>=1024?(n/1024).toFixed(1)+' KB':n+' B';
async function digest(data){return Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',data)),b=>b.toString(16).padStart(2,'0')).join('');}
async function unchanged(handle,original,hash){const current=await handle.getFile();return current.size===original.size&&current.lastModified===original.lastModified&&await digest(await current.arrayBuffer())===hash;}
function base64Label(label){const b=new TextEncoder().encode(label.slice(-600));let s='';for(const x of b)s+=String.fromCharCode(x);return btoa(s);}
async function api(route,body,headers={}){for(let attempt=0;attempt<7;attempt++){stopped();const r=await fetch(route,{method:'POST',headers:{'Authorization':'Bearer '+state.token,...headers},body,credentials:'omit',cache:'no-store'});if(r.status===429){await delay(2000);continue;}const data=await r.json();if(!r.ok){if(r.status===401){state.ready=false;controls();}throw new Error(data.error||'服务端拒绝请求');}return data;}throw new Error('服务器持续繁忙，请稍后重试');}
function upload(file,label,sourceHash,index,total){return new Promise((resolve,reject)=>{const xhr=new XMLHttpRequest();state.xhr=xhr;xhr.open('POST','/api/decrypt');xhr.responseType='arraybuffer';xhr.timeout=300000;xhr.setRequestHeader('Authorization','Bearer '+state.token);xhr.setRequestHeader('Content-Type','application/octet-stream');xhr.setRequestHeader('X-Content-SHA256',sourceHash);xhr.setRequestHeader('X-File-Label',base64Label(label));xhr.upload.onprogress=e=>{if(e.lengthComputable){$('phase').textContent='上传 '+label+' · '+bytes(e.loaded)+' / '+bytes(e.total);$('progress').value=(index+0.8*e.loaded/e.total)/Math.max(1,total);}};xhr.onload=()=>{state.xhr=null;if(xhr.status===200)resolve({data:xhr.response,hash:xhr.getResponseHeader('X-Plain-SHA256')});else if(xhr.status===204)resolve({skipped:true});else if(xhr.status===429)resolve({busy:true});else{let msg='服务端处理失败（'+xhr.status+'）';try{msg=JSON.parse(new TextDecoder().decode(xhr.response)).error||msg;}catch{}reject(new Error(msg));}};xhr.onerror=()=>{state.xhr=null;reject(new Error('网络连接失败，未写回原文件'));};xhr.ontimeout=()=>{state.xhr=null;reject(new Error('请求超时，未写回原文件'));};xhr.onabort=()=>{state.xhr=null;reject(new DOMException('已停止','AbortError'));};xhr.send(file);});}
async function processOne(item,mode,index,total){if(item.error)throw new Error(item.error);const original=item.handle.name;if(!/\.ps1$/i.test(original))return processCore(item,mode,index,total);if(typeof item.handle.move!=='function')throw new Error('此浏览器不支持改名，无法安全处理 .ps1 文件');const suffix=Array.from(crypto.getRandomValues(new Uint8Array(4)),b=>b.toString(16).padStart(2,'0')).join('');const temporary=original.slice(0,-4)+'.'+suffix+'.txt';await item.handle.move(temporary);try{return await processCore(item,mode,index,total);}finally{try{await item.handle.move(original);}catch(e){throw new Error('处理结束后无法改回 '+original+'，文件当前名为 '+temporary+'：'+e.message);}}}
async function processCore(item,mode,index,total){stopped();if(item.error)throw new Error(item.error);const file=await item.handle.getFile();const prefix=await file.slice(0,512).arrayBuffer();const h=new Uint8Array(prefix);const family=h.length>=2&&(h[0]&0xf0)===0x80&&h[1]===0x7d;
if(!family){state.stats.skipped++;result(item.label,'未加密','未发现加密包头，保持原文件');return;}
const detection=await api('/api/inspect',prefix,{'Content-Type':'application/octet-stream','X-File-Length':String(file.size)});
if(detection.kind==='Plain'){state.stats.skipped++;result(item.label,'未加密','保持原文件');return;}
if(detection.kind!=='Supported')throw new Error(detection.message||'不支持或损坏的加密头');state.stats.encrypted++;
if(mode==='inspect'){result(item.label,'已加密',detection.message+'；仅检测，未修改',{encrypted:true});return;}
if(file.size>state.maxBytes)throw new Error('文件 '+bytes(file.size)+' 超过单文件上限 '+bytes(state.maxBytes));
$('phase').textContent='计算上传校验值 · '+item.label;const sourceHash=await digest(await file.arrayBuffer());stopped();let decoded;
for(let attempt=0;attempt<7;attempt++){decoded=await upload(file,item.label,sourceHash,index,total);if(!decoded.busy)break;await delay(2000);stopped();}
if(!decoded||decoded.busy)throw new Error('服务器繁忙，未修改原文件');if(decoded.skipped){state.stats.skipped++;result(item.label,'跳过','服务端未发现加密头，保持原文件');return;}
stopped();$('phase').textContent='核验结果 · '+item.label;if(!/^[0-9a-f]{64}$/i.test(decoded.hash||'')||await digest(decoded.data)!==decoded.hash.toLowerCase())throw new Error('解密响应校验失败，未修改原文件');
if(!await unchanged(item.handle,file,sourceHash))throw new Error('处理期间原文件发生变化，拒绝覆盖');stopped();
let writer=null;state.writing=true;controls();try{$('phase').textContent='原位写回 · '+item.label;writer=await item.handle.createWritable({keepExistingData:false,mode:'exclusive'});await writer.write(decoded.data);stopped();if(!await unchanged(item.handle,file,sourceHash))throw new Error('写回提交前原文件发生变化，已取消覆盖');await writer.close();writer=null;}catch(e){if(writer)try{await writer.abort();}catch{}throw e;}finally{state.writing=false;controls();}
state.stats.written++;result(item.label,'已解密','核验通过并原位写回 · '+bytes(decoded.data.byteLength),{encrypted:true,written:true});}
async function walk(directory,prefix,list){try{for await(const [name,handle] of directory.entries()){stopped();const label=prefix+'/'+name;if(handle.kind==='directory')await walk(handle,label,list);else list.push({handle,label});if(list.length>50000){const error=new Error('本次文件夹超过 50000 个项目，请选择更小的子目录');error.name='LimitError';throw error;}}}catch(error){if(error.name==='AbortError'||error.name==='LimitError')throw error;list.push({label:prefix+'/',error:'无法读取目录：'+error.message});}}
async function select(kind){if(state.busy||!state.ready)return;const mode=document.querySelector('input[name=mode]:checked').value;let selected;
try{if(kind==='file'){[selected]=await window.showOpenFilePicker({multiple:false,excludeAcceptAllOption:false});if(mode==='decrypt'&&await selected.requestPermission({mode:'readwrite'})!=='granted')throw new Error('没有获得该文件的写入权限');}else selected=await window.showDirectoryPicker({mode:mode==='decrypt'?'readwrite':'read'});
if(mode==='decrypt'&&!window.confirm('将检查所选'+(kind==='file'?'文件':'文件夹及其子文件夹')+'，并直接替换能解密的文件。普通文件跳过；失败不强行写回。请先备份重要资料。是否继续？'))return;
}catch(e){if(e.name!=='AbortError')message(e.message,true);return;}
state.busy=true;state.cancel=false;state.rows=[];state.stats={total:0,encrypted:0,written:0,skipped:0,failed:0};stats();render();controls();$('progress').value=0;message('处理只作用于你主动选择并授权的本地文件。');
try{const list=[];$('phase').textContent='枚举所选文件…';if(kind==='file')list.push({handle:selected,label:selected.name});else await walk(selected,selected.name,list);state.stats.total=list.length;stats();
for(let i=0;i<list.length;i++){stopped();$('phase').textContent='['+(i+1)+'/'+list.length+'] '+list[i].label;try{await processOne(list[i],mode,i,list.length);}catch(e){if(e.name==='AbortError'&&state.cancel)throw e;state.stats.failed++;result(list[i].label,'失败',e.message,{failed:true});}stats();$('progress').value=(i+1)/Math.max(1,list.length);}
message(mode==='inspect'?'检测完成，所有原文件保持不变。':'处理完成：成功写回 '+state.stats.written+'，跳过 '+state.stats.skipped+'，失败 '+state.stats.failed+'。');$('phase').textContent=list.length?'本次处理完成':'所选文件夹为空';
}catch(e){message(e.name==='AbortError'?'本次处理已停止，未开始写回的文件保持不变。':e.message,e.name!=='AbortError');$('phase').textContent='已停止';}finally{state.busy=false;state.writing=false;state.xhr=null;controls();}}
$('loginForm').addEventListener('submit',async e=>{e.preventDefault();state.cancel=false;state.token=$('password').value;try{const info=await api('/api/session',null);state.ready=true;state.maxBytes=info.maxFileBytes;$('password').value='';$('connection').textContent='已连接';$('connectionInfo').textContent='连接成功 · 单文件解密上限 '+bytes(state.maxBytes)+' · 检测只发送疑似文件头';message('请选择操作，然后选择文件或文件夹。');}catch(error){state.ready=false;state.token='';message(error.message,true);}controls();});
$('chooseFile').addEventListener('click',()=>select('file'));$('chooseFolder').addEventListener('click',()=>select('folder'));
$('cancel').addEventListener('click',()=>{state.cancel=true;if(state.xhr)state.xhr.abort();message('正在停止；已完成写回的文件不会回滚。');});$('filter').addEventListener('change',render);
$('copyFailures').addEventListener('click',async()=>{const text=state.rows.filter(x=>x.failed).map(x=>x.label+'\t'+x.detail).join('\n');try{await navigator.clipboard.writeText(text||'没有失败文件');message('失败清单已复制。');}catch{message('浏览器不允许访问剪贴板，请在结果中查看失败信息。',true);}});
document.addEventListener('dragover',e=>e.preventDefault());document.addEventListener('drop',e=>{e.preventDefault();message('不支持拖拽，请使用选择文件或选择文件夹按钮。');});
window.addEventListener('beforeunload',e=>{if(state.busy){e.preventDefault();e.returnValue='';}});
if(capable){$('capability').textContent='当前浏览器支持本地目录授权。请连接服务；原位写回前会再次确认，文件名和目录结构保持不变。';}else{$('capability').classList.add('warning');$('capability').textContent='当前环境不能原位访问文件。请使用桌面版 Edge / Chrome，并通过已受信任的 HTTPS 地址打开。不会降级为下载或擅自改动文件。';}controls();
</script></body></html>
'@

if ($LoadOnly) { return }

function Assert-ServerHttps([string]$Address, [int]$ListenPort) {
    $path = Get-HttpsStatePath $Address $ListenPort
    if (-not (Test-Path -LiteralPath $path)) { throw '请先点击“配置 HTTPS（管理员）”，完成监听权限和证书绑定。' }
    $config = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $cert = Get-Item -LiteralPath ('Cert:\LocalMachine\My\' + $config.Thumbprint) -ErrorAction SilentlyContinue
    if (-not $cert -or $cert.NotAfter -le (Get-Date)) { throw 'HTTPS 证书不存在或已过期，请重新配置。' }
    return $config
}

if ($Headless) {
    if ($HttpLocalTest -and $BindAddress -ne '127.0.0.1') { throw 'HTTP 测试模式只允许 127.0.0.1；局域网必须使用 HTTPS。' }
    if (-not $HttpLocalTest) { $null = Assert-ServerHttps $BindAddress $Port }
    if (-not $Password) { $Password = New-ServerPassword }
    $hostServer = New-Object UnlockLan.Server -ArgumentList $ServerPage,$BindAddress,$Port,(-not $HttpLocalTest),$Password,([long]$MaxFileMB * 1MB),$Workers,$StateDirectory
    try {
        $hostServer.Start()
        Write-Host ('Listening: ' + $hostServer.Url)
        Write-Host ('Access password (not saved in logs): ' + $Password)
        Write-Host ('Logs: ' + $hostServer.LogDirectory)
        Write-Host 'Ctrl+C to stop. HTTP is permitted only for local testing.'
        while ($hostServer.Running) { Start-Sleep -Milliseconds 400; foreach ($line in $hostServer.DrainLogs()) { Write-Host $line } }
    } finally { $hostServer.Stop() }
    return
}

# Give the launcher its own hidden-console STA process; never hide the user's
# existing terminal. Minimize/close of this window will subsequently use tray.
if (-not $GuiProcess) {
    $arguments = '-NoProfile -ExecutionPolicy Bypass -STA -File "' + $ServerScriptPath + '" -GuiProcess -BindAddress ' + $BindAddress + ' -Port ' + $Port + ' -MaxFileMB ' + $MaxFileMB + ' -Workers ' + $Workers + ' -StateDirectory "' + $StateDirectory + '"'
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -WindowStyle Hidden -ArgumentList $arguments | Out-Null
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:hostServer = $null
$script:setupProcess = $null
$script:exitRequested = $false
$script:ipChoices = @()

$form = New-Object Windows.Forms.Form
$form.Text = 'Ophelia — 启动器（关闭窗口进入托盘）'
$form.Size = New-Object Drawing.Size 1000,805
$form.MinimumSize = New-Object Drawing.Size 940,760
$form.StartPosition = 'CenterScreen'
$form.Font = [Drawing.Font]::new('Microsoft YaHei UI',[single]9,[Drawing.FontStyle]::Regular)
$form.BackColor = [Drawing.Color]::FromArgb(244,247,252)
$form.Icon = [Drawing.SystemIcons]::Shield

function Add-ServerLabel([string]$Text,[int]$X,[int]$Y,[int]$Width,[int]$Height=24) {
    $c = New-Object Windows.Forms.Label
    $c.Text=$Text; $c.SetBounds($X,$Y,$Width,$Height); $form.Controls.Add($c); return $c
}
function Add-ServerButton([string]$Text,[int]$X,[int]$Y,[int]$Width) {
    $c=New-Object Windows.Forms.Button
    $c.Text=$Text; $c.SetBounds($X,$Y,$Width,32); $form.Controls.Add($c); return $c
}
$title=Add-ServerLabel 'Ophelia' 20 16 800 32
$title.Font=[Drawing.Font]::new('Microsoft YaHei UI',[single]17,[Drawing.FontStyle]::Bold)
$null=Add-ServerLabel '单文件启动 · 文件/文件夹授权后原位处理 · 独立检测模式 · 不执行上传内容' 22 51 930 24
$null=Add-ServerLabel '本地 IP' 22 88 95
$ipBox=New-Object Windows.Forms.ComboBox
$ipBox.DropDownStyle='DropDownList'; $ipBox.SetBounds(120,84,420,30); $form.Controls.Add($ipBox)
$refreshButton=Add-ServerButton '刷新 IP' 550 82 90
$null=Add-ServerLabel '端口' 665 88 45
$portBox=New-Object Windows.Forms.NumericUpDown
$portBox.Minimum=1; $portBox.Maximum=65535; $portBox.Value=$Port; $portBox.SetBounds(715,85,110,28); $form.Controls.Add($portBox)
$null=Add-ServerLabel '单文件上限' 22 128 95
$sizeBox=New-Object Windows.Forms.NumericUpDown
$sizeBox.Minimum=1; $sizeBox.Maximum=2048; $sizeBox.Value=$MaxFileMB; $sizeBox.SetBounds(120,124,100,28); $form.Controls.Add($sizeBox)
$null=Add-ServerLabel 'MB' 230 128 35
$null=Add-ServerLabel '并发处理' 290 128 90
$workerBox=New-Object Windows.Forms.NumericUpDown
$workerBox.Minimum=1; $workerBox.Maximum=8; $workerBox.Value=$Workers; $workerBox.SetBounds(385,124,65,28); $form.Controls.Add($workerBox)
$null=Add-ServerLabel '访问口令' 22 168 95
$tokenBox=New-Object Windows.Forms.TextBox
$tokenBox.SetBounds(120,164,420,28); $tokenBox.UseSystemPasswordChar=$true
$tokenBox.Text=New-ServerPassword; $form.Controls.Add($tokenBox)
$generateButton=Add-ServerButton '重新生成' 550 162 90
$copyTokenButton=Add-ServerButton '复制口令' 650 162 95
$showToken=New-Object Windows.Forms.CheckBox
$showToken.Text='显示';$showToken.SetBounds(765,167,90,24);$form.Controls.Add($showToken)
$showToken.Add_CheckedChanged({$tokenBox.UseSystemPasswordChar=-not $showToken.Checked})
$configureButton=Add-ServerButton '配置 HTTPS（管理员）' 20 208 185
$exportButton=Add-ServerButton '导出公钥证书' 215 208 125
$dnsButton=Add-ServerButton '名称访问说明' 350 208 130
$logsButton=Add-ServerButton '打开日志目录' 490 208 130
$startButton=Add-ServerButton '启动服务' 660 206 140
$stopButton=Add-ServerButton '停止服务' 815 206 140
$stopButton.Enabled=$false
$statusLabel=Add-ServerLabel '服务未启动。首次使用请先配置 HTTPS。' 22 255 930 26
$statusLabel.ForeColor=[Drawing.Color]::FromArgb(60,88,135)
$urlBox=New-Object Windows.Forms.TextBox
$urlBox.SetBounds(20,287,790,75);$urlBox.Multiline=$true;$urlBox.ReadOnly=$true;$urlBox.Font=[Drawing.Font]::new('Consolas',[single]10,[Drawing.FontStyle]::Regular);$form.Controls.Add($urlBox)
$copyUrlButton=Add-ServerButton '复制 IP 地址' 825 287 130
$openButton=Add-ServerButton '打开网页' 825 329 130
$notice=Add-ServerLabel 'HTTPS 配置会申请管理员确认，只允许所选 IP 的专用网络/本地子网。首次给同事使用，请导出公钥证书并让其信任，再用 Edge / Chrome 打开。名称解析不保证可用，IP 地址始终保留。最小化或点关闭进入托盘；右键托盘可退出。' 22 377 930 62
$notice.ForeColor=[Drawing.Color]::FromArgb(100,114,136)
$statsLabel=Add-ServerLabel '服务端统计：当前处理 0 · 已解密并传回 0 · 失败 0（客户端本地跳过不计入）' 22 447 930 26
$logBox=New-Object Windows.Forms.TextBox
$logBox.SetBounds(20,480,935,218);$logBox.Multiline=$true;$logBox.ReadOnly=$true;$logBox.ScrollBars='Both';$logBox.WordWrap=$false
$logBox.Font=[Drawing.Font]::new('Consolas',[single]9,[Drawing.FontStyle]::Regular);$logBox.BackColor=[Drawing.Color]::FromArgb(17,30,51);$logBox.ForeColor=[Drawing.Color]::FromArgb(193,209,232)
$logBox.Anchor='Top,Bottom,Left,Right';$form.Controls.Add($logBox)
$logPathLabel=Add-ServerLabel ('日志：'+(Join-Path $StateDirectory 'logs')+'（不保存口令和文件正文）') 22 713 930 40
$logPathLabel.Anchor='Bottom,Left,Right'

$trayMenu=New-Object Windows.Forms.ContextMenuStrip
$restoreItem=$trayMenu.Items.Add('恢复启动器')
$openItem=$trayMenu.Items.Add('打开网页')
$copyItem=$trayMenu.Items.Add('复制 IP 访问地址')
$trayStopItem=$trayMenu.Items.Add('停止服务')
$null=$trayMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$exitItem=$trayMenu.Items.Add('退出程序')
$tray=New-Object Windows.Forms.NotifyIcon
$tray.Icon=[Drawing.SystemIcons]::Shield;$tray.Text='Ophelia — 未启动';$tray.ContextMenuStrip=$trayMenu;$tray.Visible=$true

function Get-SelectedAddress {
    if($ipBox.SelectedIndex -lt 0){throw '没有可用 IP，请刷新。'}
    $script:ipChoices[$ipBox.SelectedIndex].Address
}
function Update-ServerAddresses {
    if($ipBox.SelectedIndex -lt 0){return}
    $address=Get-SelectedAddress;$p=[int]$portBox.Value;$suffix=if($p -eq 443){''}else{':'+$p}
    $lines=@('IP：https://'+$address+$suffix+'/')
    if($address -ne '127.0.0.1'){
        $lines+=('电脑名：https://'+$env:COMPUTERNAME.ToLowerInvariant()+$suffix+'/ （需本地名称解析）')
        $lines+=('别名：https://ophelia'+$suffix+'/ （需 DNS/hosts 支持，不会自动配置路由器）')
    }
    $urlBox.Text=$lines -join [Environment]::NewLine
}
function Refresh-ServerIPs {
    $selected=if($ipBox.SelectedIndex -ge 0){Get-SelectedAddress}else{$BindAddress}
    $script:ipChoices=@(Get-ServerIPv4);$ipBox.Items.Clear()
    foreach($item in $script:ipChoices){$null=$ipBox.Items.Add($item.Display)}
    $index=0;for($i=0;$i -lt $script:ipChoices.Count;$i++){if($script:ipChoices[$i].Address -eq $selected){$index=$i;break}}
    $ipBox.SelectedIndex=$index;Update-ServerAddresses
}
function Set-LauncherControls {
    $running=$script:hostServer -and $script:hostServer.Running
    $setting=$null -ne $script:setupProcess
    foreach($c in @($ipBox,$portBox,$sizeBox,$workerBox,$tokenBox,$generateButton,$configureButton,$refreshButton)){$c.Enabled=-not $running -and -not $setting}
    $startButton.Enabled=-not $running -and -not $setting
    $stopButton.Enabled=[bool]$running;$trayStopItem.Enabled=[bool]$running
    $tray.Text=if($running){'Ophelia — 服务运行中'}else{'Ophelia — 未启动'}
}
function Show-Launcher {
    $form.WindowState='Normal';$form.ShowInTaskbar=$true;$form.Show();$form.Activate()
}
function Hide-Launcher {
    $form.Hide();$form.ShowInTaskbar=$false
    $tray.ShowBalloonTip(2500,'Ophelia','启动器已进入托盘，服务状态不变。双击恢复，右键可退出。',[Windows.Forms.ToolTipIcon]::Info)
}
function Stop-LauncherServer {
    if($script:hostServer){$script:hostServer.Stop()}
    $statusLabel.Text='服务已停止。';Set-LauncherControls
}
function Open-ServerPage {
    $address=Get-SelectedAddress;$p=[int]$portBox.Value;$suffix=if($p -eq 443){''}else{':'+$p}
    Start-Process ('https://'+$address+$suffix+'/') | Out-Null
}
function Copy-ServerAddress {
    $address=Get-SelectedAddress;$p=[int]$portBox.Value;$suffix=if($p -eq 443){''}else{':'+$p}
    [Windows.Forms.Clipboard]::SetText('https://'+$address+$suffix+'/')
}

$refreshButton.Add_Click({try{Refresh-ServerIPs}catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'IP 刷新失败')|Out-Null}})
$ipBox.Add_SelectedIndexChanged({Update-ServerAddresses})
$portBox.Add_ValueChanged({Update-ServerAddresses})
$generateButton.Add_Click({$tokenBox.Text=New-ServerPassword})
$copyTokenButton.Add_Click({[Windows.Forms.Clipboard]::SetText($tokenBox.Text)})
$copyUrlButton.Add_Click({Copy-ServerAddress});$copyItem.Add_Click({Copy-ServerAddress})
$openButton.Add_Click({Open-ServerPage});$openItem.Add_Click({Open-ServerPage})
$logsButton.Add_Click({$p=Join-Path $StateDirectory 'logs';[IO.Directory]::CreateDirectory($p)|Out-Null;Start-Process explorer.exe -ArgumentList ('"'+$p+'"')|Out-Null})
$dnsButton.Add_Click({[Windows.Forms.MessageBox]::Show("无需改路由器即可使用 IP 地址。`r`n`r`n电脑名访问依赖局域网现有的 DNS / LLMNR / NetBIOS；有些网络可直接使用，但不保证。`r`n`r`nhttps://ophelia/（或旧别名 https://unlock/）需要 DNS 或客户端 hosts 将名称指向所选 IP，并使用 443 端口。单个服务器脚本不能保证所有设备自动解析裸词。浏览器也可能把裸词当搜索词，请输入完整 https 地址。`r`n`r`n本脚本不改电脑名、路由器或其他设备的 DNS。",'Ophelia 名称访问')|Out-Null})
$configureButton.Add_Click({
    try{
        $address=Get-SelectedAddress;$p=[int]$portBox.Value
        $text="将配置 HTTPS 证书和当前用户的监听权限。`r`n局域网仅开放所选 IP、专用网络、本地子网的端口 $p。`r`n不会覆盖其他服务的 HTTPS 绑定。是否继续？"
        if([Windows.Forms.MessageBox]::Show($text,'HTTPS 配置','YesNo','Question') -ne 'Yes'){return}
        $args='-NoProfile -ExecutionPolicy Bypass -File "'+$ServerScriptPath+'" -ConfigureHttps -BindAddress '+$address+' -Port '+$p+' -StateDirectory "'+$StateDirectory+'" -TargetUser "'+[Security.Principal.WindowsIdentity]::GetCurrent().Name+'"'
        $script:setupProcess=Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs -ArgumentList $args -PassThru
        $statusLabel.Text='正在配置 HTTPS，请完成管理员确认…';Set-LauncherControls
    }catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'HTTPS 配置未完成')|Out-Null}
})
$exportButton.Add_Click({
    try{
        $config=Assert-ServerHttps (Get-SelectedAddress) ([int]$portBox.Value)
        $dialog=New-Object Windows.Forms.SaveFileDialog;$dialog.Filter='公钥证书 (*.cer)|*.cer';$dialog.FileName=[IO.Path]::GetFileName($config.PublicCertificate)
        if($dialog.ShowDialog() -eq 'OK'){
            Copy-Item -LiteralPath $config.PublicCertificate -Destination $dialog.FileName -Force
            $fingerprint=(Get-FileHash -LiteralPath $dialog.FileName -Algorithm SHA256).Hash
            [Windows.Forms.MessageBox]::Show("只导出公钥，不包含私钥。`r`n`r`n证书 SHA-256：`r`n$fingerprint`r`n`r`nWindows 证书指纹：`r`n$($config.Thumbprint)`r`n`r`n请通过可信方式交给客户端，核对指纹后导入当前用户的受信任的根证书颁发机构。也可由单位管理员部署组织信任的证书。",'证书已导出')|Out-Null
        };$dialog.Dispose()
    }catch{[Windows.Forms.MessageBox]::Show($_.Exception.Message,'无法导出')|Out-Null}
})
$startButton.Add_Click({
    try{
        $address=Get-SelectedAddress;$p=[int]$portBox.Value;$null=Assert-ServerHttps $address $p
        $script:hostServer=New-Object UnlockLan.Server -ArgumentList $ServerPage,$address,$p,$true,$tokenBox.Text,([long]$sizeBox.Value*1MB),([int]$workerBox.Value),$StateDirectory
        $script:hostServer.Start();$statusLabel.Text='服务运行中。请将地址、公钥证书和访问口令分别提供给授权用户。';Set-LauncherControls
    }catch{if($script:hostServer){$script:hostServer.Stop()};$statusLabel.Text='启动失败：'+$_.Exception.GetBaseException().Message;Set-LauncherControls;[Windows.Forms.MessageBox]::Show($statusLabel.Text,'启动失败')|Out-Null}
})
$stopButton.Add_Click({Stop-LauncherServer});$trayStopItem.Add_Click({Stop-LauncherServer})
$restoreItem.Add_Click({Show-Launcher});$tray.Add_DoubleClick({Show-Launcher})
$exitItem.Add_Click({
    if($script:hostServer -and $script:hostServer.Running){if([Windows.Forms.MessageBox]::Show('退出会停止服务，并中断尚未完成的请求。已写回文件不会回滚。是否退出？','退出','YesNo','Question') -ne 'Yes'){return}}
    $script:exitRequested=$true;Stop-LauncherServer;$tray.Visible=$false;$form.Close()
})
$form.Add_Resize({if($form.WindowState -eq 'Minimized'){Hide-Launcher}})
$form.Add_FormClosing({param($sender,$eventArgs)if(-not $script:exitRequested){$eventArgs.Cancel=$true;Hide-Launcher}})
$timer=New-Object Windows.Forms.Timer;$timer.Interval=400
$timer.Add_Tick({
    if($script:hostServer){
        foreach($line in $script:hostServer.DrainLogs()){$logBox.AppendText($line+[Environment]::NewLine)}
        if($logBox.TextLength -gt 180000){$logBox.Text=$logBox.Text.Substring($logBox.TextLength-90000)}
        $statsLabel.Text='服务端统计：当前处理 '+$script:hostServer.Active+' · 已解密并传回 '+$script:hostServer.Succeeded+' · 失败 '+$script:hostServer.Failed+'（客户端本地跳过不计入）'
        if(-not $script:hostServer.Running){Set-LauncherControls;if($statusLabel.Text.StartsWith('服务运行中')){$statusLabel.Text='服务已停止，请查看日志。'}}
    }
    if($script:setupProcess -and $script:setupProcess.HasExited){
        $code=$script:setupProcess.ExitCode;$script:setupProcess.Dispose();$script:setupProcess=$null
        $statusLabel.Text=if($code -eq 0){'HTTPS 已配置。请导出公钥证书供客户端信任，再启动服务。'}else{'HTTPS 配置未完成，错误信息位于 '+(Join-Path $StateDirectory 'https-setup-error.log')}
        Set-LauncherControls
    }
})
Refresh-ServerIPs;Set-LauncherControls;$timer.Start()
try{[Windows.Forms.Application]::Run($form)}finally{if($script:hostServer){$script:hostServer.Stop()};$timer.Stop();$timer.Dispose();$tray.Visible=$false;$tray.Dispose();$trayMenu.Dispose();$form.Dispose()}
