const rendering = @import("vulkan.zig");
const vk = @import("vulkan");
const std = @import("std");
const Context = @import("../ctx.zig").Context;

pub const Shader = struct {
    e_vulkan: *rendering.EggyVulkanInterface,
    module: vk.ShaderModule,

    /// Helper function to create a shader module from SPIR-V contents.
    pub fn init_from_file(e_vulkan: *rendering.EggyVulkanInterface, file: std.Io.File, ctx: *Context) !@This() {
        var buf: [4096]u8 = undefined;
        var reader = std.Io.File.Reader.init(file, ctx.proc_init.io, &buf);
        const contents = try reader.interface.allocRemaining(ctx.allocator, .unlimited);
        defer ctx.allocator.free(contents);

        return try Shader.init(e_vulkan, contents);
    }

    /// Create a shader module from SPIR-V contents.
    pub fn init(e_vulkan: *rendering.EggyVulkanInterface, spirv_contents: []const u8) !@This() {
        const shader_create_info: vk.ShaderModuleCreateInfo = .{
            .code_size = spirv_contents.len,
            .p_code = @ptrCast(@alignCast(spirv_contents.ptr)),
        };

        const module = try e_vulkan.device.createShaderModule(
            &shader_create_info,
            null,
        );

        return .{
            .e_vulkan = e_vulkan,
            .module = module,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.e_vulkan.device.destroyShaderModule(self.module, null);
    }
};

pub const CompareOp = enum {
    never,
    less,
    equal,
    less_or_equal,
    greater,
    not_equal,
    greater_or_equal,
    always,

    fn toVk(self: CompareOp) vk.CompareOp {
        return switch (self) {
            .never => .never,
            .less => .less,
            .equal => .equal,
            .less_or_equal => .less_or_equal,
            .greater => .greater,
            .not_equal => .not_equal,
            .greater_or_equal => .greater_or_equal,
            .always => .always,
        };
    }
};

pub const Topology = enum {
    point_list,
    line_list,
    line_strip,
    triangle_list,
    triangle_strip,
    triangle_fan,

    fn toVk(self: Topology) vk.PrimitiveTopology {
        return switch (self) {
            .point_list => .point_list,
            .line_list => .line_list,
            .line_strip => .line_strip,
            .triangle_list => .triangle_list,
            .triangle_strip => .triangle_strip,
            .triangle_fan => .triangle_fan,
        };
    }
};

pub const CullMode = enum {
    none,
    front,
    back,
    front_and_back,

    fn toVk(self: CullMode) vk.CullModeFlags {
        return switch (self) {
            .none => .{},
            .front => .{ .front_bit = true },
            .back => .{ .back_bit = true },
            .front_and_back => .{ .front_bit = true, .back_bit = true },
        };
    }
};

pub const FrontFace = enum {
    clockwise,
    counter_clockwise,

    fn toVk(self: FrontFace) vk.FrontFace {
        return switch (self) {
            .clockwise => .clockwise,
            .counter_clockwise => .counter_clockwise,
        };
    }
};

pub const PolygonMode = enum {
    fill,
    line,
    point,

    fn toVk(self: PolygonMode) vk.PolygonMode {
        return switch (self) {
            .fill => .fill,
            .line => .line,
            .point => .point,
        };
    }
};

pub const BlendFactor = enum {
    zero,
    one,
    src_color,
    one_minus_src_color,
    dst_color,
    one_minus_dst_color,
    src_alpha,
    one_minus_src_alpha,
    dst_alpha,
    one_minus_dst_alpha,

    fn toVk(self: BlendFactor) vk.BlendFactor {
        return switch (self) {
            .zero => .zero,
            .one => .one,
            .src_color => .src_color,
            .one_minus_src_color => .one_minus_src_color,
            .dst_color => .dst_color,
            .one_minus_dst_color => .one_minus_dst_color,
            .src_alpha => .src_alpha,
            .one_minus_src_alpha => .one_minus_src_alpha,
            .dst_alpha => .dst_alpha,
            .one_minus_dst_alpha => .one_minus_dst_alpha,
        };
    }
};

pub const BlendOp = enum {
    add,
    subtract,
    reverse_subtract,
    min,
    max,

    fn toVk(self: BlendOp) vk.BlendOp {
        return switch (self) {
            .add => .add,
            .subtract => .subtract,
            .reverse_subtract => .reverse_subtract,
            .min => .min,
            .max => .max,
        };
    }
};

pub const BlendConfig = struct {
    enabled: bool = false,
    src_color: BlendFactor = .one,
    dst_color: BlendFactor = .zero,
    color_op: BlendOp = .add,
    src_alpha: BlendFactor = .one,
    dst_alpha: BlendFactor = .zero,
    alpha_op: BlendOp = .add,

    /// Standard alpha blending: src.rgb * src.a + dst.rgb * (1 - src.a)
    pub const alpha_blend = BlendConfig{
        .enabled = true,
        .src_color = .src_alpha,
        .dst_color = .one_minus_src_alpha,
        .color_op = .add,
        .src_alpha = .one,
        .dst_alpha = .zero,
        .alpha_op = .add,
    };

    /// Additive blending: src.rgb + dst.rgb
    pub const additive = BlendConfig{
        .enabled = true,
        .src_color = .one,
        .dst_color = .one,
        .color_op = .add,
        .src_alpha = .one,
        .dst_alpha = .one,
        .alpha_op = .add,
    };
};

/// Shader stage flags for descriptor bindings.
pub const ShaderStage = packed struct {
    vertex: bool = false,
    fragment: bool = false,
    geometry: bool = false,
    tessellation_control: bool = false,
    tessellation_evaluation: bool = false,
    compute: bool = false,

    pub const all_graphics: ShaderStage = .{
        .vertex = true,
        .fragment = true,
        .geometry = true,
        .tessellation_control = true,
        .tessellation_evaluation = true,
    };

    pub fn toVk(self: ShaderStage) vk.ShaderStageFlags {
        return .{
            .vertex_bit = self.vertex,
            .fragment_bit = self.fragment,
            .geometry_bit = self.geometry,
            .tessellation_control_bit = self.tessellation_control,
            .tessellation_evaluation_bit = self.tessellation_evaluation,
            .compute_bit = self.compute,
        };
    }
};

/// What kind of resource is bound?
pub const DescriptorType = enum {
    uniform_buffer,
    storage_buffer,
    uniform_buffer_dynamic,
    storage_buffer_dynamic,
    combined_image_sampler,
    sampled_image,
    storage_image,
    sampler,
    input_attachment,

    pub fn toVk(self: DescriptorType) vk.DescriptorType {
        return switch (self) {
            .uniform_buffer => .uniform_buffer,
            .storage_buffer => .storage_buffer,
            .uniform_buffer_dynamic => .uniform_buffer_dynamic,
            .storage_buffer_dynamic => .storage_buffer_dynamic,
            .combined_image_sampler => .combined_image_sampler,
            .sampled_image => .sampled_image,
            .storage_image => .storage_image,
            .sampler => .sampler,
            .input_attachment => .input_attachment,
        };
    }
};

/// Describes a single binding in a descriptor set layout.
pub const DescriptorBinding = struct {
    /// Binding number in the shader (layout(binding = N)).
    binding: u32,
    descriptor_type: DescriptorType,
    count: u32 = 1,
    stage_flags: ShaderStage,

    /// Create a uniform buffer binding for vertex shader.
    pub fn uniformBuffer(binding: u32, stages: ShaderStage) DescriptorBinding {
        return .{
            .binding = binding,
            .descriptor_type = .uniform_buffer,
            .count = 1,
            .stage_flags = stages,
        };
    }

    /// Create a combined image sampler binding.
    pub fn combinedImageSampler(binding: u32, stages: ShaderStage) DescriptorBinding {
        return .{
            .binding = binding,
            .descriptor_type = .combined_image_sampler,
            .count = 1,
            .stage_flags = stages,
        };
    }

    /// Create a storage buffer binding.
    pub fn storageBuffer(binding: u32, stages: ShaderStage) DescriptorBinding {
        return .{
            .binding = binding,
            .descriptor_type = .storage_buffer,
            .count = 1,
            .stage_flags = stages,
        };
    }

    pub fn toVk(self: DescriptorBinding) vk.DescriptorSetLayoutBinding {
        return .{
            .binding = self.binding,
            .descriptor_type = self.descriptor_type.toVk(),
            .descriptor_count = self.count,
            .stage_flags = self.stage_flags.toVk(),
            .p_immutable_samplers = null,
        };
    }
};

pub const VertexInputRate = enum {
    vertex,
    instance,

    fn toVk(self: VertexInputRate) vk.VertexInputRate {
        return switch (self) {
            .vertex => .vertex,
            .instance => .instance,
        };
    }
};

pub const VertexFormat = enum {
    float1,
    float2,
    float3,
    float4,
    int1,
    int2,
    int3,
    int4,
    uint1,
    uint2,
    uint3,
    uint4,

    fn toVk(self: VertexFormat) vk.Format {
        return switch (self) {
            .float1 => .r32_sfloat,
            .float2 => .r32g32_sfloat,
            .float3 => .r32g32b32_sfloat,
            .float4 => .r32g32b32a32_sfloat,
            .int1 => .r32_sint,
            .int2 => .r32g32_sint,
            .int3 => .r32g32b32_sint,
            .int4 => .r32g32b32a32_sint,
            .uint1 => .r32_uint,
            .uint2 => .r32g32_uint,
            .uint3 => .r32g32b32_uint,
            .uint4 => .r32g32b32a32_uint,
        };
    }
};

pub const VertexBinding = struct {
    binding: u32 = 0,
    stride: u32,
    input_rate: VertexInputRate = .vertex,

    pub fn toVk(self: VertexBinding) vk.VertexInputBindingDescription {
        return .{
            .binding = self.binding,
            .stride = self.stride,
            .input_rate = self.input_rate.toVk(),
        };
    }
};

pub const VertexAttribute = struct {
    location: u32,
    binding: u32 = 0,
    format: VertexFormat,
    offset: u32,

    pub fn toVk(self: VertexAttribute) vk.VertexInputAttributeDescription {
        return .{
            .location = self.location,
            .binding = self.binding,
            .format = self.format.toVk(),
            .offset = self.offset,
        };
    }
};

pub const Pipeline = struct {
    vulkan: *rendering.EggyVulkanInterface,
    handle: vk.Pipeline,
    layout: vk.PipelineLayout,
    descriptor_set_layout: vk.DescriptorSetLayout,

    pub fn deinit(self: *Pipeline) void {
        self.vulkan.await() catch {};
        self.vulkan.device.destroyPipeline(self.handle, null);
        self.vulkan.device.destroyPipelineLayout(self.layout, null);
        if (self.descriptor_set_layout != .null_handle) {
            self.vulkan.device.destroyDescriptorSetLayout(self.descriptor_set_layout, null);
        }
    }

    /// Start building a new graphics pipeline.
    pub fn builder(vulkan: *rendering.EggyVulkanInterface, allocator: std.mem.Allocator, label: ?[*:0]const u8) PipelineBuilder {
        return PipelineBuilder.init(vulkan, allocator, label);
    }
};

pub const PipelineBuilder = struct {
    vulkan: *rendering.EggyVulkanInterface,
    allocator: std.mem.Allocator,
    label: ?[*:0]const u8,

    // Shader stages
    vert_module: ?vk.ShaderModule = null,
    vert_entry: [*:0]const u8 = "main",
    frag_module: ?vk.ShaderModule = null,
    frag_entry: [*:0]const u8 = "main",

    // Vertex input
    binding_descriptions: std.ArrayList(vk.VertexInputBindingDescription),
    attribute_descriptions: std.ArrayList(vk.VertexInputAttributeDescription),

    // Input assembly
    topology_value: Topology = .triangle_list,
    primitive_restart: bool = false,

    // Rasterization
    polygon_mode_value: PolygonMode = .fill,
    cull_mode_value: CullMode = .back,
    front_face_value: FrontFace = .clockwise,
    line_width_value: f32 = 1.0,
    depth_clamp: bool = false,
    rasterizer_discard: bool = false,

    // Depth/stencil
    depth_test: bool = false,
    depth_write: bool = false,
    depth_compare_op: CompareOp = .less,
    depth_format: vk.Format = .undefined,

    // Multisampling
    samples: u8 = 1,

    // Color blending
    blend_config: BlendConfig = .{},

    // Dynamic state
    dynamic_viewport: bool = true,
    dynamic_scissor: bool = true,

    // Color format (defaults to swapchain format)
    color_format_override: ?vk.Format = null,

    // Descriptor set layout bindings
    descriptor_bindings: std.ArrayList(vk.DescriptorSetLayoutBinding),

    pub fn init(vulkan: *rendering.EggyVulkanInterface, allocator: std.mem.Allocator, label: ?[*:0]const u8) PipelineBuilder {
        return .{
            .vulkan = vulkan,
            .allocator = allocator,
            .binding_descriptions = std.ArrayList(vk.VertexInputBindingDescription).empty,
            .attribute_descriptions = std.ArrayList(vk.VertexInputAttributeDescription).empty,
            .descriptor_bindings = std.ArrayList(vk.DescriptorSetLayoutBinding).empty,
            .label = label,
        };
    }

    pub fn deinit(self: *PipelineBuilder) void {
        self.binding_descriptions.deinit(self.allocator);
        self.attribute_descriptions.deinit(self.allocator);
        self.descriptor_bindings.deinit(self.allocator);
    }

    /// Set the vertex shader module and entry point.
    pub fn vertexShader(self: *PipelineBuilder, module: vk.ShaderModule, entry: [*:0]const u8) *PipelineBuilder {
        self.vert_module = module;
        self.vert_entry = entry;
        return self;
    }

    /// Set the fragment shader module and entry point.
    pub fn fragmentShader(self: *PipelineBuilder, module: vk.ShaderModule, entry: [*:0]const u8) *PipelineBuilder {
        self.frag_module = module;
        self.frag_entry = entry;
        return self;
    }

    /// Add a vertex binding (describes the stride and input rate for a vertex buffer).
    pub fn addVertexBinding(self: *PipelineBuilder, binding: VertexBinding) *PipelineBuilder {
        self.binding_descriptions.append(self.allocator, binding.toVk()) catch {};
        return self;
    }

    /// Add a vertex attribute (describes a single field in the vertex struct).
    pub fn addVertexAttribute(self: *PipelineBuilder, attr: VertexAttribute) *PipelineBuilder {
        return self.addVertexAttributes(&.{attr});
    }

    /// Add multiple vertex attributes at once.
    pub fn addVertexAttributes(self: *PipelineBuilder, attrs: []const VertexAttribute) *PipelineBuilder {
        for (attrs) |attr| {
            self.attribute_descriptions.append(self.allocator, attr.toVk()) catch {};
        }
        return self;
    }

    /// Set primitive topology (triangle_list, line_list, etc.)
    pub fn topology(self: *PipelineBuilder, t: Topology) *PipelineBuilder {
        self.topology_value = t;
        return self;
    }

    /// Set polygon rasterization mode (fill, line, point)
    pub fn polygonMode(self: *PipelineBuilder, mode: PolygonMode) *PipelineBuilder {
        self.polygon_mode_value = mode;
        return self;
    }

    /// Set face culling mode
    pub fn cullMode(self: *PipelineBuilder, mode: CullMode) *PipelineBuilder {
        self.cull_mode_value = mode;
        return self;
    }

    /// Set front face winding order
    pub fn frontFace(self: *PipelineBuilder, face: FrontFace) *PipelineBuilder {
        self.front_face_value = face;
        return self;
    }

    /// Set line width for line rendering
    pub fn lineWidth(self: *PipelineBuilder, width: f32) *PipelineBuilder {
        self.line_width_value = width;
        return self;
    }

    /// Enable/disable depth testing
    pub fn depthTest(self: *PipelineBuilder, enabled: bool) *PipelineBuilder {
        self.depth_test = enabled;
        return self;
    }

    /// Enable/disable depth writing
    pub fn depthWrite(self: *PipelineBuilder, enabled: bool) *PipelineBuilder {
        self.depth_write = enabled;
        return self;
    }

    /// Set color blending configuration
    pub fn blend(self: *PipelineBuilder, config: BlendConfig) *PipelineBuilder {
        self.blend_config = config;
        return self;
    }

    /// Override the color attachment format (defaults to swapchain format)
    pub fn colorFormat(self: *PipelineBuilder, format: vk.Format) *PipelineBuilder {
        self.color_format_override = format;
        return self;
    }

    /// Add a descriptor binding to the pipeline's descriptor set layout.
    pub fn addDescriptorBinding(self: *PipelineBuilder, binding: DescriptorBinding) *PipelineBuilder {
        self.descriptor_bindings.append(self.allocator, binding.toVk()) catch {};
        return self;
    }

    /// Add multiple descriptor bindings at once.
    pub fn addDescriptorBindings(self: *PipelineBuilder, bindings: []const DescriptorBinding) *PipelineBuilder {
        for (bindings) |binding| {
            self.descriptor_bindings.append(self.allocator, binding.toVk()) catch {};
        }
        return self;
    }

    pub fn depthCompareOp(self: *PipelineBuilder, op: CompareOp) *PipelineBuilder {
        self.depth_compare_op = op;
        return self;
    }

    pub fn depthFormat(self: *PipelineBuilder, format: vk.Format) *PipelineBuilder {
        self.depth_format = format;
        return self;
    }

    /// Build the pipeline. Returns error if shaders are not set.
    pub fn build(self: *PipelineBuilder) !Pipeline {
        const vert = self.vert_module orelse return error.MissingVertexShader;
        const frag = self.frag_module orelse return error.MissingFragmentShader;

        // Shader stages
        const stages = [_]vk.PipelineShaderStageCreateInfo{
            .{
                .stage = .{ .vertex_bit = true },
                .module = vert,
                .p_name = self.vert_entry,
            },
            .{
                .stage = .{ .fragment_bit = true },
                .module = frag,
                .p_name = self.frag_entry,
            },
        };

        const vertex_input = vk.PipelineVertexInputStateCreateInfo{
            .vertex_binding_description_count = @intCast(self.binding_descriptions.items.len),
            .p_vertex_binding_descriptions = if (self.binding_descriptions.items.len > 0) self.binding_descriptions.items.ptr else null,
            .vertex_attribute_description_count = @intCast(self.attribute_descriptions.items.len),
            .p_vertex_attribute_descriptions = if (self.attribute_descriptions.items.len > 0) self.attribute_descriptions.items.ptr else null,
        };

        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .topology = self.topology_value.toVk(),
            .primitive_restart_enable = if (self.primitive_restart) .true else .false,
        };

        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .viewport_count = 1,
            .scissor_count = 1,
        };

        const rasterization = vk.PipelineRasterizationStateCreateInfo{
            .depth_clamp_enable = if (self.depth_clamp) .true else .false,
            .rasterizer_discard_enable = if (self.rasterizer_discard) .true else .false,
            .polygon_mode = self.polygon_mode_value.toVk(),
            .cull_mode = self.cull_mode_value.toVk(),
            .front_face = self.front_face_value.toVk(),
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0.0,
            .depth_bias_clamp = 0.0,
            .depth_bias_slope_factor = 0.0,
            .line_width = self.line_width_value,
        };

        const sample_flag: vk.SampleCountFlags = switch (self.samples) {
            1 => .{ .@"1_bit" = true },
            2 => .{ .@"2_bit" = true },
            4 => .{ .@"4_bit" = true },
            8 => .{ .@"8_bit" = true },
            16 => .{ .@"16_bit" = true },
            32 => .{ .@"32_bit" = true },
            else => .{ .@"1_bit" = true },
        };
        const multisampling = vk.PipelineMultisampleStateCreateInfo{
            .rasterization_samples = sample_flag,
            .sample_shading_enable = .false,
            .min_sample_shading = 1.0,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        };

        const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
            .blend_enable = if (self.blend_config.enabled) .true else .false,
            .src_color_blend_factor = self.blend_config.src_color.toVk(),
            .dst_color_blend_factor = self.blend_config.dst_color.toVk(),
            .color_blend_op = self.blend_config.color_op.toVk(),
            .src_alpha_blend_factor = self.blend_config.src_alpha.toVk(),
            .dst_alpha_blend_factor = self.blend_config.dst_alpha.toVk(),
            .alpha_blend_op = self.blend_config.alpha_op.toVk(),
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        };

        const color_blending = vk.PipelineColorBlendStateCreateInfo{
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&color_blend_attachment),
            .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        var dynamic_states_buf: [2]vk.DynamicState = undefined;
        var dynamic_count: u32 = 0;
        if (self.dynamic_viewport) {
            dynamic_states_buf[dynamic_count] = .viewport;
            dynamic_count += 1;
        }
        if (self.dynamic_scissor) {
            dynamic_states_buf[dynamic_count] = .scissor;
            dynamic_count += 1;
        }
        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .dynamic_state_count = dynamic_count,
            .p_dynamic_states = &dynamic_states_buf,
        };

        var descriptor_set_layout: vk.DescriptorSetLayout = .null_handle;
        if (self.descriptor_bindings.items.len > 0) {
            const descriptor_layout_info = vk.DescriptorSetLayoutCreateInfo{
                .binding_count = @intCast(self.descriptor_bindings.items.len),
                .p_bindings = self.descriptor_bindings.items.ptr,
            };
            descriptor_set_layout = try self.vulkan.device.createDescriptorSetLayout(&descriptor_layout_info, null);
        }
        errdefer if (descriptor_set_layout != .null_handle) {
            self.vulkan.device.destroyDescriptorSetLayout(descriptor_set_layout, null);
        };

        const layout_info = vk.PipelineLayoutCreateInfo{
            .set_layout_count = if (descriptor_set_layout != .null_handle) 1 else 0,
            .p_set_layouts = if (descriptor_set_layout != .null_handle) @ptrCast(&descriptor_set_layout) else null,
            .push_constant_range_count = 0,
        };
        const layout = try self.vulkan.device.createPipelineLayout(&layout_info, null);
        errdefer self.vulkan.device.destroyPipelineLayout(layout, null);

        const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = if (self.depth_test) .true else .false,
            .depth_write_enable = if (self.depth_write) .true else .false,
            .depth_compare_op = self.depth_compare_op.toVk(),
            .depth_bounds_test_enable = .false,
            .stencil_test_enable = .false,
            .front = std.mem.zeroes(vk.StencilOpState),
            .back = std.mem.zeroes(vk.StencilOpState),
            .min_depth_bounds = 0.0,
            .max_depth_bounds = 1.0,
        };

        const color_fmt = self.color_format_override orelse self.vulkan.swapchain.surface_format.format;
        const rendering_info = vk.PipelineRenderingCreateInfo{
            .color_attachment_count = 1,
            .p_color_attachment_formats = @ptrCast(&color_fmt),
            .depth_attachment_format = self.depth_format,
            .stencil_attachment_format = .undefined,
            .view_mask = 0,
        };

        const pipeline_info = vk.GraphicsPipelineCreateInfo{
            .p_next = @ptrCast(&rendering_info),
            .stage_count = 2,
            .p_stages = &stages,
            .p_vertex_input_state = &vertex_input,
            .p_input_assembly_state = &input_assembly,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &rasterization,
            .p_multisample_state = &multisampling,
            .p_color_blend_state = &color_blending,
            .p_dynamic_state = &dynamic_state,
            .layout = layout,
            .render_pass = .null_handle,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
            .p_depth_stencil_state = &depth_stencil,
        };

        var pipeline: vk.Pipeline = undefined;
        _ = try self.vulkan.device.createGraphicsPipelines(
        .null_handle,
            &.{pipeline_info},
            null,
            (&pipeline)[0..1],
        );
        rendering.vkSetName(self.vulkan.device, vk.Pipeline, pipeline, self.label);
        std.log.debug("Initialised new pipeline '{any}", .{self.label});

        return Pipeline{
            .vulkan = self.vulkan,
            .handle = pipeline,
            .layout = layout,
            .descriptor_set_layout = descriptor_set_layout,
        };
    }
};
