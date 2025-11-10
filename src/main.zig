const std = @import("std");
const builtin = @import("builtin");
const zemscripten = @import("zemscripten");

const c = @cImport({
    @cInclude("emscripten.h");
    @cInclude("webgpu/webgpu.h");
});

pub const panic = zemscripten.panic;

pub const std_options = std.Options{
    .logFn = zemscripten.log,
};

const Window = struct {
    name: []const u8 = "",
    width: i32 = 0,
    height: i32 = 0,
};

const Wgpu = struct {
    instance: c.WGPUInstance = null,
    device: c.WGPUDevice = null,
    queue: c.WGPUQueue = null,
    surface: c.WGPUSurface = null,
    renderPipeline: c.WGPURenderPipeline = null,
    computePipeline: c.WGPUComputePipeline = null,
};

const ComputeBuffers = struct {
    storage: c.WGPUBuffer = null,
    staging: c.WGPUBuffer = null,
    size: usize = 0,
    computeBindGroup: c.WGPUBindGroup = null,
};

const State = struct {
    fps: f64 = 0,
    frameCount: u32 = 0,
    computeRan: bool = false,
    computeSubmitted: bool = false,
    lastFrameTime: f64 = 0,
    frameTime: f64 = 0,
    deltaTime: f64 = 0,
    second: f64 = 0,
};

var window = Window{};
var wgpu = Wgpu{};
var compute_buffers = ComputeBuffers{};

var state = State{};

const triangle_shader = @embedFile("triangle.wgsl");
const computeShader = @embedFile("compute.wgsl");

fn setupPipelines(computeBufferSize: u64) void {
    const triangle = createShader(triangle_shader, "rgb triangle shader");

    // Render pipeline setup

    const render_pipeline_layout = c.wgpuDeviceCreatePipelineLayout( //
        wgpu.device, //
        &c.WGPUPipelineLayoutDescriptor{
            .label = wgpuString("Render Pipeline Layout"),
        } //
    );

    wgpu.renderPipeline = c.wgpuDeviceCreateRenderPipeline( //
        wgpu.device, //
        &c.WGPURenderPipelineDescriptor{ //
            .label = wgpuString("Red Triangle Pipeline"),
            .layout = render_pipeline_layout,
            .primitive = .{
                .frontFace = c.WGPUFrontFace_CCW,
                .cullMode = c.WGPUCullMode_None,
                .topology = c.WGPUPrimitiveTopology_TriangleList,
                .stripIndexFormat = c.WGPUIndexFormat_Undefined,
            },
            .vertex = c.WGPUVertexState{
                .entryPoint = wgpuString("vs"),
                .module = triangle,
            },
            .fragment = &c.WGPUFragmentState{
                .entryPoint = wgpuString("fs"),
                .module = triangle,
                .targetCount = 1,
                .targets = &c.WGPUColorTargetState{
                    .format = c.WGPUTextureFormat_BGRA8Unorm,
                    .writeMask = c.WGPUColorWriteMask_All,
                },
            },
            .multisample = .{
                .count = 1,
                .mask = 0xFFFFFFFF,
                .alphaToCoverageEnabled = 0,
            },
            .depthStencil = null,
        });

    // Compute pipeline setup

    const doubler = createShader(computeShader, "compute shader");

    compute_buffers.storage = c.wgpuDeviceCreateBuffer(wgpu.device, &c.WGPUBufferDescriptor{
        .label = wgpuString("Compute Input Buffer"),
        .usage = c.WGPUBufferUsage_Storage | c.WGPUBufferUsage_CopySrc | c.WGPUBufferUsage_CopyDst,
        .size = computeBufferSize,
    });

    compute_buffers.staging = c.wgpuDeviceCreateBuffer(wgpu.device, &c.WGPUBufferDescriptor{
        .label = wgpuString("Compute Output Buffer"),
        .usage = c.WGPUBufferUsage_MapRead | c.WGPUBufferUsage_CopyDst,
        .size = computeBufferSize,
        .mappedAtCreation = 0,
    });

    const compute_bind_group_layout = c.wgpuDeviceCreateBindGroupLayout(wgpu.device, &c.WGPUBindGroupLayoutDescriptor{
        .label = wgpuString("Compute Bind Group Layout"),
        .entryCount = 1,
        .entries = &c.WGPUBindGroupLayoutEntry{
            .binding = 0,
            .visibility = c.WGPUShaderStage_Compute,
            .buffer = c.WGPUBufferBindingLayout{
                .type = c.WGPUBufferBindingType_Storage,
            },
        },
    });

    compute_buffers.computeBindGroup = c.wgpuDeviceCreateBindGroup(wgpu.device, &c.WGPUBindGroupDescriptor{
        .label = wgpuString("Compute Pipeline Bind Group"),
        .layout = compute_bind_group_layout,
        .entryCount = 1,
        .entries = &c.WGPUBindGroupEntry{
            .binding = 0,
            .buffer = compute_buffers.storage,
            .offset = 0,
            .size = computeBufferSize,
        },
    });

    const compute_pipeline_layout = c.wgpuDeviceCreatePipelineLayout( //
        wgpu.device, //
        &c.WGPUPipelineLayoutDescriptor{
            .label = wgpuString("Compute Pipeline Layout"),
            .bindGroupLayoutCount = 1,
            .bindGroupLayouts = &[1]c.WGPUBindGroupLayout{compute_bind_group_layout},
        } //
    );

    wgpu.computePipeline = c.wgpuDeviceCreateComputePipeline(wgpu.device, &c.WGPUComputePipelineDescriptor{
        .label = wgpuString("Compute Pipeline"),
        .layout = compute_pipeline_layout,
        .compute = c.WGPUComputeState{
            .module = doubler,
            .entryPoint = wgpuString("computeSomething"),
        },
    });
}

fn createShader(code: [*:0]const u8, label: [*:0]const u8) c.WGPUShaderModule {
    const shader_source = c.WGPUShaderSourceWGSL{
        .chain = .{
            .next = null,
            .sType = c.WGPUSType_ShaderSourceWGSL,
        },
        .code = wgpuDynamicString(code),
    };

    const descriptor = c.WGPUShaderModuleDescriptor{
        .nextInChain = @constCast(&shader_source.chain),
        .label = wgpuDynamicString(label),
    };

    return c.wgpuDeviceCreateShaderModule( //
        wgpu.device, //
        &descriptor);
}

fn createSurface() void {
    const html_selector = c.WGPUEmscriptenSurfaceSourceCanvasHTMLSelector{
        .chain = .{
            .next = null,
            .sType = c.WGPUSType_EmscriptenSurfaceSourceCanvasHTMLSelector,
        },
        .selector = wgpuString(window.name),
    };

    const descriptor = c.WGPUSurfaceDescriptor{
        .label = wgpuString("WebGPU Surface"),
        .nextInChain = @constCast(&html_selector.chain),
    };
    wgpu.surface = c.wgpuInstanceCreateSurface(wgpu.instance, &descriptor);
}

fn configureSurface() void {
    const surfaceConfig = c.WGPUSurfaceConfiguration{
        .device = wgpu.device,
        .format = c.WGPUTextureFormat_BGRA8Unorm,
        .usage = c.WGPUTextureUsage_RenderAttachment,
        .width = @intCast(window.width),
        .height = @intCast(window.height),
        .presentMode = c.WGPUPresentMode_Fifo,
        .alphaMode = c.WGPUCompositeAlphaMode_Auto,
    };
    c.wgpuSurfaceConfigure(wgpu.surface, &surfaceConfig);
}

fn onDeviceRequestEnded(status: c.WGPURequestDeviceStatus, device: c.WGPUDevice, message: c.struct_WGPUStringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void {
    _ = userdata1;
    _ = userdata2;

    if (status == c.WGPURequestDeviceStatus_Success) {
        wgpu.device = device;
        wgpu.queue = c.wgpuDeviceGetQueue(wgpu.device);
        configureSurface();

        init();

        zemscripten.setMainLoop(mainLoopCallback, null, false);

        std.log.info("WebGPU device obtained successfully!", .{});
    } else {
        if (message.length != 0) {
            std.log.err("Failed to get WebGPU device: {s}", .{message.data});
        } else {
            std.log.err("Failed to get WebGPU device: unknown error", .{});
        }
    }
}

fn onAdapterRequestEnded(status: c.WGPURequestAdapterStatus, adapter: c.WGPUAdapter, message: c.struct_WGPUStringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void {
    _ = userdata1;
    _ = userdata2;

    if (status == c.WGPURequestAdapterStatus_Success) {
        std.log.info("WebGPU adapter obtained, requesting device...", .{});

        const device_desc = c.WGPUDeviceDescriptor{
            .label = wgpuString("WebGPU Device Descriptor"),
        };
        const callback_info = c.WGPURequestDeviceCallbackInfo{
            .nextInChain = null,
            .mode = c.WGPUCallbackMode_AllowSpontaneous,
            .callback = onDeviceRequestEnded,
            .userdata1 = null,
            .userdata2 = null,
        };
        _ = c.wgpuAdapterRequestDevice(adapter, &device_desc, callback_info);
        // Callback will be called asynchronously, no need to wait in emscripten
    } else {
        if (message.length != 0) {
            std.log.err("Failed to get WebGPU adapter: {s}", .{message.data});
        } else {
            std.log.err("Failed to get WebGPU adapter: unknown error", .{});
        }
    }
}

fn startWebGPU() void {
    std.log.info("Initializing WebGPU...", .{});

    window.name = "canvas";
    window.width = 800;
    window.height = 600;

    wgpu.instance = c.wgpuCreateInstance(null);
    if (wgpu.instance == null) {
        std.log.err("Failed to create WebGPU instance", .{});
        return;
    }
    createSurface();

    const adapter_options = c.WGPURequestAdapterOptions{
        .compatibleSurface = wgpu.surface,
        // .powerPreference = c.WGPUPowerPreference_HighPerformance,
    };
    const callback_info = c.WGPURequestAdapterCallbackInfo{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowSpontaneous,
        .callback = onAdapterRequestEnded,
        .userdata1 = null,
        .userdata2 = null,
    };
    _ = c.wgpuInstanceRequestAdapter(wgpu.instance, &adapter_options, callback_info);
    // Callback will be called asynchronously, no need to wait in emscripten
}

fn draw() void {
    var surfaceTexture: c.WGPUSurfaceTexture = undefined;
    c.wgpuSurfaceGetCurrentTexture(wgpu.surface, &surfaceTexture);

    if (surfaceTexture.status != c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal) {
        std.log.err("Failed to get current surface texture: status = {}", .{surfaceTexture.status});
        if (surfaceTexture.status == c.WGPUSurfaceGetCurrentTextureStatus_Timeout or
            surfaceTexture.status == c.WGPUSurfaceGetCurrentTextureStatus_Outdated or
            surfaceTexture.status == c.WGPUSurfaceGetCurrentTextureStatus_Lost)
        {
            // Need to reconfigure surface
            configureSurface();
            return;
        }
        return;
    }

    const back_buffer = c.wgpuTextureCreateView(surfaceTexture.texture, null);
    defer {
        c.wgpuTextureViewRelease(back_buffer);
        c.wgpuTextureRelease(surfaceTexture.texture);
    }

    const cmd_encoder = c.wgpuDeviceCreateCommandEncoder(wgpu.device, null);
    defer c.wgpuCommandEncoderRelease(cmd_encoder);

    const render_pass = c.wgpuCommandEncoderBeginRenderPass(cmd_encoder, &c.WGPURenderPassDescriptor{
        .colorAttachmentCount = 1,
        .colorAttachments = &c.WGPURenderPassColorAttachment{
            .view = back_buffer,
            .loadOp = c.WGPULoadOp_Clear,
            .storeOp = c.WGPUStoreOp_Store,
            .clearValue = c.WGPUColor{ .r = 0.2, .g = 0.2, .b = 0.3, .a = 1.0 },
            .depthSlice = c.WGPU_DEPTH_SLICE_UNDEFINED,
        },
    });
    defer c.wgpuRenderPassEncoderRelease(render_pass);

    c.wgpuRenderPassEncoderSetPipeline(render_pass, wgpu.renderPipeline);
    c.wgpuRenderPassEncoderDraw(render_pass, 3, 1, 0, 0);
    c.wgpuRenderPassEncoderEnd(render_pass);

    const cmd_buffer = c.wgpuCommandEncoderFinish(cmd_encoder, null);
    defer c.wgpuCommandBufferRelease(cmd_buffer);

    c.wgpuQueueSubmit(wgpu.queue, 1, &cmd_buffer);

    // Note: wgpuSurfacePresent is not needed in Emscripten - presentation happens automatically
}

fn onBufferMapped(status: c_uint, message: c.WGPUStringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void {
    _ = userdata1;
    _ = userdata2;

    std.log.info("onBufferMapped called with status: {}", .{status});

    // BufferMapAsyncStatus: Success = 1, others are errors
    if (status != 1) {
        std.log.err("Buffer mapping failed with status: {}", .{status});
        if (message.length != 0) {
            std.log.err("Buffer mapping error message: {s}", .{message.data});
        }
        return;
    }

    std.log.info("Buffer mapped successfully, reading data...", .{});

    var result: [4]f32 = undefined;
    const read_status = c.wgpuBufferReadMappedRange(compute_buffers.staging, 0, &result, compute_buffers.size);

    if (read_status != 1) {
        std.log.err("wgpuBufferReadMappedRange failed with status: {}", .{read_status});
        return;
    }

    std.log.info("Compute shader output: {d}, {d}, {d}, {d}", .{ result[0], result[1], result[2], result[3] });

    c.wgpuBufferUnmap(compute_buffers.staging);
}
fn onQueueWorkDone(status: c.WGPUQueueWorkDoneStatus, message: c.WGPUStringView, userdata1: ?*anyopaque, userdata2: ?*anyopaque) callconv(.c) void {
    _ = userdata1;
    _ = userdata2;

    std.log.info("called onQueueWorkDone with status: {}", .{status});
    std.log.info("called onQueueWorkDone with message: {s}", .{message.data});
    if (status != c.WGPUQueueWorkDoneStatus_Success) {
        std.log.err("Queue work done failed with status: {}", .{status});
        std.log.err("Queue work done failed with message: {s}", .{message.data});
        return;
    }

    std.log.info("Queue work done, mapping buffer...", .{});

    const callbackInfo = c.WGPUBufferMapCallbackInfo{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowSpontaneous,
        .callback = onBufferMapped,
        .userdata1 = null,
        .userdata2 = null,
    };

    _ = c.wgpuBufferMapAsync(compute_buffers.staging, c.WGPUMapMode_Read, 0, compute_buffers.size, callbackInfo);
}

fn compute() void {
    if (state.computeRan) {
        return;
    }
    const cmd_encoder = c.wgpuDeviceCreateCommandEncoder(wgpu.device, null);
    defer c.wgpuCommandEncoderRelease(cmd_encoder);

    const compute_pass = c.wgpuCommandEncoderBeginComputePass(cmd_encoder, null);
    defer c.wgpuComputePassEncoderRelease(compute_pass);

    c.wgpuComputePassEncoderSetPipeline(compute_pass, wgpu.computePipeline);
    c.wgpuComputePassEncoderSetBindGroup(compute_pass, 0, compute_buffers.computeBindGroup, 0, null);
    c.wgpuComputePassEncoderDispatchWorkgroups(compute_pass, 4, 1, 1);
    c.wgpuComputePassEncoderEnd(compute_pass);

    c.wgpuCommandEncoderCopyBufferToBuffer(cmd_encoder, compute_buffers.storage, 0, compute_buffers.staging, 0, @sizeOf(f32) * 4);
    const cmd_buffer = c.wgpuCommandEncoderFinish(cmd_encoder, null);
    defer c.wgpuCommandBufferRelease(cmd_buffer);

    c.wgpuQueueSubmit(wgpu.queue, 1, &cmd_buffer);
    const queueCallbackInfo = c.WGPUQueueWorkDoneCallbackInfo{
        .nextInChain = null,
        .mode = c.WGPUCallbackMode_AllowSpontaneous,
        .callback = onQueueWorkDone,
        .userdata1 = null,
        .userdata2 = null,
    };
    _ = c.wgpuQueueOnSubmittedWorkDone(wgpu.queue, queueCallbackInfo);
    state.computeRan = true;
}

fn gameLogic() void {
    const now = c.emscripten_get_now(); // Returns milliseconds as f64
    state.frameCount += 1;
    state.deltaTime = now - state.lastFrameTime;
    state.lastFrameTime = now;
    state.frameTime = state.deltaTime;
    state.second += state.deltaTime;
    if (state.second > 1000.0) { // 1000ms = 1 second
        state.fps = @as(f64, @floatFromInt(state.frameCount)) / (state.second / 1000.0);
        std.log.debug("fps: {d:.1}", .{state.fps});
        state.second -= 1000.0;
        state.frameCount = 0;
    }
}

fn mainLoopCallback() callconv(.c) void {
    // Process WebGPU callbacks
    // c.wgpuInstanceProcessEvents(wgpu.instance);

    gameLogic();
    draw();
    compute();
    // std.log.info("Main loop tick...", .{});
}

fn setupData() void {
    const inputData: [4]f32 = .{ 1.0, 2.0, 3.0, 4.0 };
    compute_buffers.size = @sizeOf(f32) * inputData.len;

    c.wgpuQueueWriteBuffer(wgpu.queue, compute_buffers.storage, 0, &inputData, compute_buffers.size);
}

fn init() void {
    setupPipelines(@sizeOf(f32) * 4);
    setupData();
}

export fn main() c_int {
    std.log.info("Starting minimal WebGPU application...", .{});
    std.log.info("Running on {s} architecture", .{@tagName(builtin.cpu.arch)});

    startWebGPU();

    return 0;
}

fn wgpuString(str: []const u8) c.WGPUStringView {
    return c.WGPUStringView{
        .data = str.ptr,
        .length = @intCast(str.len),
    };
}

fn wgpuDynamicString(str: [*]const u8) c.WGPUStringView {
    var len: usize = 0;
    while (str[len] != 0) : (len += 1) {}
    return c.WGPUStringView{
        .data = str,
        .length = @intCast(len),
    };
}
