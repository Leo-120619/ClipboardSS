using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using ClipboardSS.Core.Models;
using ClipboardSS.Core.Protocol;
using ClipboardSS.Core.Sync;

namespace ClipboardSS.App.Net;

public sealed class MdnsService : IDisposable
{
    private const uint DnsRequestPending = 9506;
    private const ushort DnsTypePtr = 12;
    private readonly DeviceIdentity _identity;
    /// <summary>mDNS record TTL assumed when the browse callback does not carry one (RFC 6762 default for PTR).</summary>
    private static readonly TimeSpan DefaultTtl = TimeSpan.FromSeconds(4500);
    private static readonly TimeSpan PruneInterval = TimeSpan.FromSeconds(30);
    /// <summary>Peers keyed by service instance; removed on goodbye (TTL 0) or when their TTL runs out.</summary>
    private readonly MdnsPeerTable _peers = new();
    /// <summary>TTL of the latest PTR record per service instance, applied when its resolve completes.</summary>
    private readonly ConcurrentDictionary<string, TimeSpan> _serviceTtls = new(StringComparer.OrdinalIgnoreCase);
    private readonly System.Threading.Timer _pruneTimer;
    private readonly ConcurrentDictionary<IntPtr, ResolveOperation> _resolveOperations = [];
    private readonly BrowseCallback _browseCallback;
    private readonly ResolveCallback _resolveCallback;
    private readonly RegisterCallback _registerCallback;
    private IntPtr _browseRequest;
    private IntPtr _browseCancel;
    private IntPtr _browseQueryName;
    private IntPtr _registerRequest;
    private IntPtr _registerInstance;
    private bool _disposed;

    public MdnsService(DeviceIdentity identity)
    {
        _identity = identity;
        _browseCallback = BrowseCompleted;
        _resolveCallback = ResolveCompleted;
        _registerCallback = RegisterCompleted;
        _pruneTimer = new System.Threading.Timer(_ => PruneExpired(), null, PruneInterval, PruneInterval);
    }

    public event EventHandler? PeersChanged;
    public IReadOnlyList<Peer> Peers => _peers.Peers
        .OrderBy(peer => peer.Name, StringComparer.CurrentCultureIgnoreCase)
        .ToArray();

    private void PruneExpired()
    {
        if (_disposed) return;
        if (_peers.Prune(DateTimeOffset.UtcNow)) PeersChanged?.Invoke(this, EventArgs.Empty);
    }

    public bool Start()
    {
        if (!OperatingSystem.IsWindows()) return false;
        try
        {
            var registered = Register();
            var browsing = Browse();
            return registered || browsing;
        }
        catch (Exception exception) when (exception is DllNotFoundException or EntryPointNotFoundException)
        {
            return false;
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _pruneTimer.Dispose();
        if (_browseCancel != IntPtr.Zero) _ = DnsServiceBrowseCancel(_browseCancel);
        if (_registerRequest != IntPtr.Zero) _ = DnsServiceDeRegister(_registerRequest, IntPtr.Zero);
        foreach (var operation in _resolveOperations.Values)
        {
            _ = DnsServiceResolveCancel(operation.CancelPointer);
            operation.Dispose();
        }
        _resolveOperations.Clear();
        Free(ref _browseRequest);
        Free(ref _browseCancel);
        Free(ref _browseQueryName);
    }

    private bool Register()
    {
        var keys = new[] { "deviceId", "deviceName", "v" };
        var values = new[]
        {
            _identity.Id.ToString("D").ToLowerInvariant(),
            ClipServerRouter.BonjourSafeTxtValue(_identity.Name),
            WireProtocol.Version.ToString(System.Globalization.CultureInfo.InvariantCulture),
        };
        using var nativeKeys = new NativeStringArray(keys);
        using var nativeValues = new NativeStringArray(values);
        var serviceName = $"{_identity.Id:D}._clipboardss._tcp.local".ToLowerInvariant();
        var hostName = $"{Environment.MachineName}.local";
        _registerInstance = DnsServiceConstructInstance(
            serviceName,
            hostName,
            IntPtr.Zero,
            IntPtr.Zero,
            51888,
            0,
            0,
            (uint)keys.Length,
            nativeKeys.Pointer,
            nativeValues.Pointer);
        if (_registerInstance == IntPtr.Zero) return false;
        var request = new DnsServiceRegisterRequest
        {
            Version = 1,
            InterfaceIndex = 0,
            ServiceInstance = _registerInstance,
            Callback = _registerCallback,
            QueryContext = IntPtr.Zero,
            Credentials = IntPtr.Zero,
            UnicastEnabled = false,
        };
        _registerRequest = Allocate(request);
        return DnsServiceRegister(_registerRequest, IntPtr.Zero) == DnsRequestPending;
    }

    private bool Browse()
    {
        _browseQueryName = Marshal.StringToHGlobalUni("_clipboardss._tcp.local");
        _browseCancel = Marshal.AllocHGlobal(IntPtr.Size);
        Marshal.WriteIntPtr(_browseCancel, IntPtr.Zero);
        _browseRequest = Allocate(new DnsServiceBrowseRequest
        {
            Version = 1,
            InterfaceIndex = 0,
            QueryName = _browseQueryName,
            Callback = _browseCallback,
            QueryContext = IntPtr.Zero,
        });
        return DnsServiceBrowse(_browseRequest, _browseCancel) == DnsRequestPending;
    }

    private void BrowseCompleted(uint status, IntPtr context, IntPtr records)
    {
        try
        {
            if (status != 0 || records == IntPtr.Zero) return;
            for (var current = records; current != IntPtr.Zero;)
            {
                var record = Marshal.PtrToStructure<DnsRecord>(current);
                if (record.Type == DnsTypePtr && record.Data != IntPtr.Zero)
                {
                    var serviceName = Marshal.PtrToStringUni(record.Data);
                    if (!string.IsNullOrWhiteSpace(serviceName) && record.Ttl == 0)
                    {
                        // mDNS goodbye: the service left the network.
                        _serviceTtls.TryRemove(serviceName, out _);
                        if (_peers.Remove(serviceName)) PeersChanged?.Invoke(this, EventArgs.Empty);
                    }
                    else if (!string.IsNullOrWhiteSpace(serviceName))
                    {
                        _serviceTtls[serviceName] = TimeSpan.FromSeconds(record.Ttl);
                        BeginResolve(serviceName);
                    }
                }
                current = record.Next;
            }
        }
        finally
        {
            if (records != IntPtr.Zero) DnsRecordListFree(records, 1);
        }
    }

    private void BeginResolve(string serviceName)
    {
        var operation = new ResolveOperation(serviceName, _resolveCallback);
        var context = GCHandle.ToIntPtr(operation.Handle);
        operation.WriteRequest(context);
        _resolveOperations[context] = operation;
        if (DnsServiceResolve(operation.RequestPointer, operation.CancelPointer) != DnsRequestPending)
        {
            _resolveOperations.TryRemove(context, out _);
            operation.Dispose();
        }
    }

    private void ResolveCompleted(uint status, IntPtr context, IntPtr instancePointer)
    {
        try
        {
            if (status != 0 || instancePointer == IntPtr.Zero) return;
            if (!_resolveOperations.TryGetValue(context, out var resolving)) return;
            var instance = Marshal.PtrToStructure<DnsServiceInstance>(instancePointer);
            var properties = ReadProperties(instance);
            // Older peers are still listed (marked "needs update"), never hidden.
            if (!properties.TryGetValue("v", out var versionText)
                || !int.TryParse(versionText, System.Globalization.NumberStyles.None,
                    System.Globalization.CultureInfo.InvariantCulture, out var version)
                || version < 1
                || !properties.TryGetValue("deviceId", out var idValue)
                || !Guid.TryParse(idValue, out var id)
                || id == _identity.Id)
            {
                return;
            }

            var host = Marshal.PtrToStringUni(instance.HostName)?.TrimEnd('.');
            if (string.IsNullOrWhiteSpace(host)) return;
            var name = properties.GetValueOrDefault("deviceName");
            if (string.IsNullOrWhiteSpace(name)) name = id.ToString("D");
            var port = instance.Port == 0 ? (ushort)51888 : instance.Port;
            var ttl = _serviceTtls.TryGetValue(resolving.ServiceName, out var recordTtl) ? recordTtl : DefaultTtl;
            _peers.Upsert(resolving.ServiceName, new Peer(id, name, host, port, version), ttl, DateTimeOffset.UtcNow);
            PeersChanged?.Invoke(this, EventArgs.Empty);
        }
        finally
        {
            if (instancePointer != IntPtr.Zero) DnsServiceFreeInstance(instancePointer);
            if (_resolveOperations.TryRemove(context, out var operation)) operation.Dispose();
        }
    }

    private void RegisterCompleted(uint status, IntPtr context, IntPtr instancePointer)
    {
        if (instancePointer != IntPtr.Zero && instancePointer != _registerInstance)
            DnsServiceFreeInstance(instancePointer);
    }

    private static Dictionary<string, string> ReadProperties(DnsServiceInstance instance)
    {
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var index = 0; index < instance.PropertyCount; index++)
        {
            var keyPointer = Marshal.ReadIntPtr(instance.Keys, index * IntPtr.Size);
            var valuePointer = Marshal.ReadIntPtr(instance.Values, index * IntPtr.Size);
            var key = Marshal.PtrToStringUni(keyPointer);
            var value = Marshal.PtrToStringUni(valuePointer);
            if (key is not null && value is not null) result[key] = value;
        }
        return result;
    }

    private static IntPtr Allocate<T>(T value) where T : struct
    {
        var pointer = Marshal.AllocHGlobal(Marshal.SizeOf<T>());
        Marshal.StructureToPtr(value, pointer, false);
        return pointer;
    }

    private static void Free(ref IntPtr pointer)
    {
        if (pointer == IntPtr.Zero) return;
        Marshal.FreeHGlobal(pointer);
        pointer = IntPtr.Zero;
    }

    private sealed class ResolveOperation : IDisposable
    {
        private int _disposed;

        public ResolveOperation(string serviceName, ResolveCallback callback)
        {
            ServiceName = serviceName;
            QueryNamePointer = Marshal.StringToHGlobalUni(serviceName);
            CancelPointer = Marshal.AllocHGlobal(IntPtr.Size);
            Marshal.WriteIntPtr(CancelPointer, IntPtr.Zero);
            Callback = callback;
            Handle = GCHandle.Alloc(this);
        }

        public string ServiceName { get; }
        public ResolveCallback Callback { get; }
        public GCHandle Handle { get; }
        public IntPtr QueryNamePointer { get; }
        public IntPtr CancelPointer { get; }
        public IntPtr RequestPointer { get; private set; }

        public void WriteRequest(IntPtr context) => RequestPointer = Allocate(new DnsServiceResolveRequest
        {
            Version = 1,
            InterfaceIndex = 0,
            QueryName = QueryNamePointer,
            Callback = Callback,
            QueryContext = context,
        });

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            if (Handle.IsAllocated) Handle.Free();
            if (RequestPointer != IntPtr.Zero) Marshal.FreeHGlobal(RequestPointer);
            Marshal.FreeHGlobal(CancelPointer);
            Marshal.FreeHGlobal(QueryNamePointer);
        }
    }

    private sealed class NativeStringArray : IDisposable
    {
        private readonly IntPtr[] _strings;
        public NativeStringArray(IEnumerable<string> values)
        {
            _strings = values.Select(Marshal.StringToHGlobalUni).ToArray();
            Pointer = Marshal.AllocHGlobal(_strings.Length * IntPtr.Size);
            for (var index = 0; index < _strings.Length; index++)
                Marshal.WriteIntPtr(Pointer, index * IntPtr.Size, _strings[index]);
        }
        public IntPtr Pointer { get; }
        public void Dispose()
        {
            foreach (var pointer in _strings) Marshal.FreeHGlobal(pointer);
            Marshal.FreeHGlobal(Pointer);
        }
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void BrowseCallback(uint status, IntPtr context, IntPtr records);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void ResolveCallback(uint status, IntPtr context, IntPtr instance);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate void RegisterCallback(uint status, IntPtr context, IntPtr instance);

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceBrowseRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr QueryName;
        [MarshalAs(UnmanagedType.FunctionPtr)] public BrowseCallback Callback;
        public IntPtr QueryContext;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceResolveRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr QueryName;
        [MarshalAs(UnmanagedType.FunctionPtr)] public ResolveCallback Callback;
        public IntPtr QueryContext;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceRegisterRequest
    {
        public uint Version;
        public uint InterfaceIndex;
        public IntPtr ServiceInstance;
        [MarshalAs(UnmanagedType.FunctionPtr)] public RegisterCallback Callback;
        public IntPtr QueryContext;
        public IntPtr Credentials;
        [MarshalAs(UnmanagedType.Bool)] public bool UnicastEnabled;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsRecord
    {
        public IntPtr Next;
        public IntPtr Name;
        public ushort Type;
        public ushort DataLength;
        public uint Flags;
        public uint Ttl;
        public uint Reserved;
        public IntPtr Data;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DnsServiceInstance
    {
        public IntPtr InstanceName;
        public IntPtr HostName;
        public IntPtr Ip4Address;
        public IntPtr Ip6Address;
        public ushort Port;
        public ushort Priority;
        public ushort Weight;
        public uint PropertyCount;
        public IntPtr Keys;
        public IntPtr Values;
        public uint InterfaceIndex;
    }

    [DllImport("dnsapi.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr DnsServiceConstructInstance(
        string serviceName,
        string hostName,
        IntPtr ip4,
        IntPtr ip6,
        ushort port,
        ushort priority,
        ushort weight,
        uint propertyCount,
        IntPtr keys,
        IntPtr values);
    [DllImport("dnsapi.dll")] private static extern uint DnsServiceRegister(IntPtr request, IntPtr cancel);
    [DllImport("dnsapi.dll")] private static extern uint DnsServiceDeRegister(IntPtr request, IntPtr cancel);
    [DllImport("dnsapi.dll")] private static extern uint DnsServiceBrowse(IntPtr request, IntPtr cancel);
    [DllImport("dnsapi.dll")] private static extern uint DnsServiceBrowseCancel(IntPtr cancel);
    [DllImport("dnsapi.dll")] private static extern uint DnsServiceResolve(IntPtr request, IntPtr cancel);
    [DllImport("dnsapi.dll")] private static extern uint DnsServiceResolveCancel(IntPtr cancel);
    [DllImport("dnsapi.dll")] private static extern void DnsServiceFreeInstance(IntPtr instance);
    [DllImport("dnsapi.dll")] private static extern void DnsRecordListFree(IntPtr recordList, int freeType);
}
