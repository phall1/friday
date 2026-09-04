const posix = @cImport({
    @cInclude("dirent.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("sys/stat.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});

/// Only the C ABI surface used below is declared here. Importing Apple's
/// umbrella audio headers fails in Zig 0.16 because Xcode 26 exposes block
/// typedefs that translate-c cannot parse.
pub const api = struct {
    pub const access = posix.access;
    pub const __error = posix.__error;
    pub const clock_gettime = posix.clock_gettime;
    pub const close = posix.close;
    pub const closedir = posix.closedir;
    pub const fstat = posix.fstat;
    pub const fsync = posix.fsync;
    pub const ftruncate = posix.ftruncate;
    pub const mkdir = posix.mkdir;
    pub const open = posix.open;
    pub const opendir = posix.opendir;
    pub const readdir = posix.readdir;
    pub const rmdir = posix.rmdir;
    pub const stat = posix.stat;
    pub const unlink = posix.unlink;
    pub const usleep = posix.usleep;
    pub const write = posix.write;

    pub const off_t = posix.off_t;
    pub const struct_stat = posix.struct_stat;
    pub const struct_timespec = posix.struct_timespec;
    pub const CLOCK_MONOTONIC = posix.CLOCK_MONOTONIC;
    pub const CLOCK_REALTIME = posix.CLOCK_REALTIME;
    pub const EINTR = posix.EINTR;
    pub const EEXIST = posix.EEXIST;
    pub const F_OK = posix.F_OK;
    pub const O_CLOEXEC = posix.O_CLOEXEC;
    pub const O_CREAT = posix.O_CREAT;
    pub const O_NOFOLLOW = posix.O_NOFOLLOW;
    pub const O_RDWR = posix.O_RDWR;
    pub const O_TRUNC = posix.O_TRUNC;
    pub const O_WRONLY = posix.O_WRONLY;

    pub const OSStatus = i32;
    pub const AudioObjectID = u32;
    pub const AudioDeviceID = AudioObjectID;
    pub const AudioObjectPropertySelector = u32;
    pub const AudioObjectPropertyScope = u32;
    pub const AudioObjectPropertyElement = u32;
    pub const AudioUnitPropertyID = u32;
    pub const AudioUnitScope = u32;
    pub const AudioUnitElement = u32;
    pub const AudioUnitRenderActionFlags = u32;

    const OpaqueAudioComponent = opaque {};
    const OpaqueAudioComponentInstance = opaque {};
    const OpaqueAudioConverter = opaque {};
    const OpaqueCFString = opaque {};
    pub const AudioComponent = ?*OpaqueAudioComponent;
    pub const AudioComponentInstance = ?*OpaqueAudioComponentInstance;
    pub const AudioUnit = AudioComponentInstance;
    pub const AudioConverterRef = ?*OpaqueAudioConverter;
    pub const CFStringRef = ?*const OpaqueCFString;
    pub const CFTypeRef = ?*const anyopaque;
    pub const CFIndex = c_long;
    pub const CFStringEncoding = u32;

    pub const AudioComponentDescription = extern struct {
        componentType: u32,
        componentSubType: u32,
        componentManufacturer: u32,
        componentFlags: u32,
        componentFlagsMask: u32,
    };

    pub const AudioStreamBasicDescription = extern struct {
        mSampleRate: f64,
        mFormatID: u32,
        mFormatFlags: u32,
        mBytesPerPacket: u32,
        mFramesPerPacket: u32,
        mBytesPerFrame: u32,
        mChannelsPerFrame: u32,
        mBitsPerChannel: u32,
        mReserved: u32,
    };

    pub const AudioBuffer = extern struct {
        mNumberChannels: u32,
        mDataByteSize: u32,
        mData: ?*anyopaque,
    };

    pub const AudioBufferList = extern struct {
        mNumberBuffers: u32,
        mBuffers: [1]AudioBuffer,
    };

    pub const AudioTimeStamp = opaque {};
    pub const AURenderCallback = ?*const fn (
        in_ref_con: ?*anyopaque,
        io_action_flags: [*c]AudioUnitRenderActionFlags,
        in_time_stamp: ?*const AudioTimeStamp,
        in_bus_number: u32,
        in_number_frames: u32,
        io_data: [*c]AudioBufferList,
    ) callconv(.c) OSStatus;

    pub const AURenderCallbackStruct = extern struct {
        inputProc: AURenderCallback,
        inputProcRefCon: ?*anyopaque,
    };

    pub const AudioObjectPropertyAddress = extern struct {
        mSelector: AudioObjectPropertySelector,
        mScope: AudioObjectPropertyScope,
        mElement: AudioObjectPropertyElement,
    };

    pub const AudioObjectPropertyListenerProc = ?*const fn (
        in_object_id: AudioObjectID,
        in_number_addresses: u32,
        in_addresses: [*c]const AudioObjectPropertyAddress,
        in_client_data: ?*anyopaque,
    ) callconv(.c) OSStatus;

    pub extern "c" fn AudioComponentFindNext(
        in_component: AudioComponent,
        in_description: *const AudioComponentDescription,
    ) AudioComponent;
    pub extern "c" fn AudioComponentInstanceNew(
        in_component: AudioComponent,
        out_instance: *AudioComponentInstance,
    ) OSStatus;
    pub extern "c" fn AudioComponentInstanceDispose(in_instance: AudioComponentInstance) OSStatus;
    pub extern "c" fn AudioUnitSetProperty(
        in_unit: AudioUnit,
        in_id: AudioUnitPropertyID,
        in_scope: AudioUnitScope,
        in_element: AudioUnitElement,
        in_data: ?*const anyopaque,
        in_data_size: u32,
    ) OSStatus;
    pub extern "c" fn AudioUnitInitialize(in_unit: AudioUnit) OSStatus;
    pub extern "c" fn AudioUnitUninitialize(in_unit: AudioUnit) OSStatus;
    pub extern "c" fn AudioOutputUnitStart(in_unit: AudioUnit) OSStatus;
    pub extern "c" fn AudioOutputUnitStop(in_unit: AudioUnit) OSStatus;
    pub extern "c" fn AudioUnitRender(
        in_unit: AudioUnit,
        io_action_flags: [*c]AudioUnitRenderActionFlags,
        in_time_stamp: ?*const AudioTimeStamp,
        in_output_bus_number: u32,
        in_number_frames: u32,
        io_data: [*c]AudioBufferList,
    ) OSStatus;

    pub extern "c" fn AudioConverterNew(
        in_source_format: *const AudioStreamBasicDescription,
        in_destination_format: *const AudioStreamBasicDescription,
        out_audio_converter: *AudioConverterRef,
    ) OSStatus;
    pub extern "c" fn AudioConverterDispose(in_audio_converter: AudioConverterRef) OSStatus;
    pub extern "c" fn AudioConverterConvertComplexBuffer(
        in_audio_converter: AudioConverterRef,
        in_number_pcm_frames: u32,
        in_input_data: *const AudioBufferList,
        out_output_data: *AudioBufferList,
    ) OSStatus;

    pub extern "c" fn AudioObjectGetPropertyDataSize(
        in_object_id: AudioObjectID,
        in_address: *const AudioObjectPropertyAddress,
        in_qualifier_data_size: u32,
        in_qualifier_data: ?*const anyopaque,
        out_data_size: *u32,
    ) OSStatus;
    pub extern "c" fn AudioObjectGetPropertyData(
        in_object_id: AudioObjectID,
        in_address: *const AudioObjectPropertyAddress,
        in_qualifier_data_size: u32,
        in_qualifier_data: ?*const anyopaque,
        io_data_size: *u32,
        out_data: ?*anyopaque,
    ) OSStatus;
    pub extern "c" fn AudioObjectAddPropertyListener(
        in_object_id: AudioObjectID,
        in_address: *const AudioObjectPropertyAddress,
        in_listener: AudioObjectPropertyListenerProc,
        in_client_data: ?*anyopaque,
    ) OSStatus;
    pub extern "c" fn AudioObjectRemovePropertyListener(
        in_object_id: AudioObjectID,
        in_address: *const AudioObjectPropertyAddress,
        in_listener: AudioObjectPropertyListenerProc,
        in_client_data: ?*anyopaque,
    ) OSStatus;

    pub extern "c" fn CFStringGetCString(
        the_string: CFStringRef,
        buffer: [*c]u8,
        buffer_size: CFIndex,
        encoding: CFStringEncoding,
    ) u8;
    pub extern "c" fn CFRelease(cf: CFTypeRef) void;

    fn fourcc(comptime value: []const u8) u32 {
        return (@as(u32, value[0]) << 24) |
            (@as(u32, value[1]) << 16) |
            (@as(u32, value[2]) << 8) |
            @as(u32, value[3]);
    }

    pub const noErr: OSStatus = 0;
    pub const kAudioObjectUnknown: AudioObjectID = 0;
    pub const kAudioObjectSystemObject: AudioObjectID = 1;
    pub const kAudioObjectPropertyElementMain: AudioObjectPropertyElement = 0;
    pub const kAudioObjectPropertyScopeGlobal = fourcc("glob");
    pub const kAudioObjectPropertyScopeInput = fourcc("inpt");
    pub const kAudioObjectPropertyName = fourcc("lnam");
    pub const kAudioHardwarePropertyDefaultInputDevice = fourcc("dIn ");
    pub const kAudioDevicePropertyDeviceIsAlive = fourcc("livn");
    pub const kAudioDevicePropertyNominalSampleRate = fourcc("nsrt");
    pub const kAudioDevicePropertyStreamConfiguration = fourcc("slay");

    pub const kAudioUnitType_Output = fourcc("auou");
    pub const kAudioUnitSubType_HALOutput = fourcc("ahal");
    pub const kAudioUnitManufacturer_Apple = fourcc("appl");
    pub const kAudioUnitScope_Global: AudioUnitScope = 0;
    pub const kAudioUnitScope_Input: AudioUnitScope = 1;
    pub const kAudioUnitScope_Output: AudioUnitScope = 2;
    pub const kAudioUnitProperty_StreamFormat: AudioUnitPropertyID = 8;
    pub const kAudioOutputUnitProperty_CurrentDevice: AudioUnitPropertyID = 2000;
    pub const kAudioOutputUnitProperty_EnableIO: AudioUnitPropertyID = 2003;
    pub const kAudioOutputUnitProperty_SetInputCallback: AudioUnitPropertyID = 2005;

    pub const kAudioFormatLinearPCM = fourcc("lpcm");
    pub const kAudioFormatFlagIsFloat: u32 = 1 << 0;
    pub const kAudioFormatFlagIsPacked: u32 = 1 << 3;
    pub const kAudioFormatFlagsNativeEndian: u32 = 0;
    pub const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;
};
