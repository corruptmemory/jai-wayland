// GL types — sizes match the standard glcorearb.h for x86_64 Linux.

GLenum     :: u32;
GLboolean  :: u8;
GLbitfield :: u32;
GLbyte     :: s8;
GLshort    :: s16;
GLint      :: s32;
GLuint     :: u32;
GLsizei    :: u32;  // matches upstream Jai GL module (the strict C API uses s32)
GLfloat    :: float32;
GLdouble   :: float64;
GLchar     :: u8;
GLintptr   :: s64;   // intptr_t on x86_64 Linux
GLsizeiptr :: s64;
GLeglImageOES :: *void;
GLuint64   :: u64;
GLsync     :: u64;

// --- Boolean constants ---
GL_FALSE :: 0;
GL_TRUE  :: 1;

// --- Buffer clear bits ---
GL_COLOR_BUFFER_BIT   :: 0x00004000;
GL_DEPTH_BUFFER_BIT   :: 0x00000100;
GL_STENCIL_BUFFER_BIT :: 0x00000400;

// --- Primitive types ---
GL_TRIANGLES :: 0x0004;

// --- Capability / draw / read targets ---
GL_NONE                 :: 0;
GL_FRONT                :: 0x0404;
GL_BACK                 :: 0x0405;
GL_CULL_FACE            :: 0x0B44;
GL_DEPTH_TEST           :: 0x0B71;
GL_BLEND                :: 0x0BE2;
GL_SCISSOR_TEST         :: 0x0C11;
GL_TEXTURE_BINDING_2D   :: 0x8069;

// --- Blend factors ---
GL_SRC_ALPHA            :: 0x0302;
GL_ONE_MINUS_SRC_ALPHA  :: 0x0303;

// --- Data types ---
GL_BYTE          :: 0x1400;
GL_UNSIGNED_BYTE :: 0x1401;
GL_SHORT         :: 0x1402;
GL_UNSIGNED_SHORT:: 0x1403;
GL_INT           :: 0x1404;
GL_UNSIGNED_INT  :: 0x1405;
GL_FLOAT         :: 0x1406;
GL_HALF_FLOAT    :: 0x140B;
GL_UNSIGNED_SHORT_5_6_5         :: 0x8363;
GL_UNSIGNED_INT_24_8            :: 0x84FA;
GL_UNSIGNED_INT_10_10_10_2      :: 0x8036;
GL_UNSIGNED_INT_10F_11F_11F_REV :: 0x8C3B;
GL_UNSIGNED_INT_5_9_9_9_REV     :: 0x8C3E;
GL_FLOAT_32_UNSIGNED_INT_24_8_REV :: 0x8DAD;

// --- Pixel formats / internal formats ---
GL_RED      :: 0x1903;
GL_RG       :: 0x8227;
GL_RGB      :: 0x1907;
GL_RGBA     :: 0x1908;
GL_BGR      :: 0x80E0;
GL_BGRA     :: 0x80E1;
GL_R8       :: 0x8229;
GL_R16      :: 0x822A;
GL_R16F     :: 0x822D;
GL_R32F     :: 0x822E;
GL_R16I     :: 0x8233;
GL_R32I     :: 0x8235;
GL_RG8      :: 0x822B;
GL_RG16F    :: 0x822F;
GL_RG32F    :: 0x8230;
GL_RG16I    :: 0x8239;
GL_RG32I    :: 0x823B;
GL_RGB8     :: 0x8051;
GL_RGB10_A2 :: 0x8059;
GL_RGB9_E5  :: 0x8C3D;
GL_R11F_G11F_B10F :: 0x8C3A;
GL_RGBA8    :: 0x8058;
GL_RGBA16F  :: 0x881A;
GL_RGBA32F  :: 0x8814;
GL_RGBA16I  :: 0x8D88;
GL_RGBA32I  :: 0x8D82;
GL_SRGB     :: 0x8C40;
GL_SRGB8    :: 0x8C41;
GL_SRGB8_ALPHA8 :: 0x8C43;
GL_DEPTH_COMPONENT      :: 0x1902;
GL_DEPTH_COMPONENT16    :: 0x81A5;
GL_DEPTH_COMPONENT32F   :: 0x8CAC;
GL_DEPTH_COMPONENT32F_NV:: 0x8DAB;
GL_DEPTH_STENCIL        :: 0x84F9;
GL_DEPTH24_STENCIL8     :: 0x88F0;
GL_DEPTH32F_STENCIL8    :: 0x8CAD;
GL_DEPTH32F_STENCIL8_NV :: 0x8DAC;

// --- Compressed formats ---
GL_COMPRESSED_RED_RGTC1               :: 0x8DBB;
GL_COMPRESSED_RG_RGTC2                :: 0x8DBD;
GL_COMPRESSED_RGB_S3TC_DXT1_EXT       :: 0x83F0;
GL_COMPRESSED_RGBA_S3TC_DXT5_EXT      :: 0x83F3;
GL_COMPRESSED_SRGB_S3TC_DXT1_EXT      :: 0x8C4C;
GL_COMPRESSED_SRGB_ALPHA_S3TC_DXT5_EXT:: 0x8C4F;
GL_COMPRESSED_RGB_BPTC_UNSIGNED_FLOAT :: 0x8E8F;
GL_COMPRESSED_RGBA_BPTC_UNORM         :: 0x8E8C;
GL_COMPRESSED_SRGB_ALPHA_BPTC_UNORM   :: 0x8E8D;

// --- Textures ---
GL_TEXTURE_2D                 :: 0x0DE1;
GL_TEXTURE_MIN_FILTER         :: 0x2801;
GL_TEXTURE_MAG_FILTER         :: 0x2800;
GL_TEXTURE_WRAP_S             :: 0x2802;
GL_TEXTURE_WRAP_T             :: 0x2803;
GL_TEXTURE_MAX_LEVEL          :: 0x813D;
GL_TEXTURE_MAX_ANISOTROPY_EXT :: 0x84FE;
GL_TEXTURE0                   :: 0x84C0;
GL_NEAREST                    :: 0x2600;
GL_LINEAR                     :: 0x2601;
GL_CLAMP_TO_EDGE              :: 0x812F;

// --- Pixel packing ---
GL_UNPACK_ALIGNMENT  :: 0x0CF5;
GL_UNPACK_ROW_LENGTH :: 0x0CF2;
GL_PIXEL_PACK_BUFFER :: 0x88EB;

// --- Framebuffer objects ---
GL_FRAMEBUFFER                  :: 0x8D40;
GL_READ_FRAMEBUFFER             :: 0x8CA8;
GL_DRAW_FRAMEBUFFER             :: 0x8CA9;
GL_READ_FRAMEBUFFER_BINDING     :: 0x8CAA;
GL_DRAW_FRAMEBUFFER_BINDING     :: 0x8CA6;
GL_COLOR_ATTACHMENT0            :: 0x8CE0;
GL_FRAMEBUFFER_COMPLETE         :: 0x8CD5;

// --- Version query ---
GL_VENDOR        :: 0x1F00;
GL_RENDERER      :: 0x1F01;
GL_VERSION       :: 0x1F02;
GL_MAJOR_VERSION :: 0x821B;
GL_MINOR_VERSION :: 0x821C;

// --- Shader / program objects (Task 8) ---
GL_VERTEX_SHADER   :: 0x8B31;
GL_FRAGMENT_SHADER :: 0x8B30;
GL_COMPILE_STATUS  :: 0x8B81;
GL_LINK_STATUS     :: 0x8B82;
GL_INFO_LOG_LENGTH :: 0x8B84;

// --- Buffer objects (Task 8) ---
GL_ARRAY_BUFFER         :: 0x8892;
GL_ELEMENT_ARRAY_BUFFER :: 0x8893;
GL_STATIC_DRAW          :: 0x88E4;
GL_DYNAMIC_DRAW         :: 0x88E8;
GL_STREAM_DRAW          :: 0x88E0;
GL_DYNAMIC_READ         :: 0x88E9;
GL_READ_ONLY            :: 0x88B8;
GL_MAP_READ_BIT         :: 0x0001;

// --- Errors ---
GL_NO_ERROR          :: 0;
GL_INVALID_ENUM      :: 0x0500;
GL_INVALID_OPERATION :: 0x0502;

// --- Function pointers ---
// All null until gl_load() populates them. Casting xx on the result of
// get_proc_address keeps each declaration one line.

// Viewport / clear / read
glViewport:    #type (x: GLint, y: GLint, width: GLsizei, height: GLsizei) #c_call;
glClearColor:  #type (r: GLfloat, g: GLfloat, b: GLfloat, a: GLfloat) #c_call;
glClear:       #type (mask: GLbitfield) #c_call;
glReadPixels:  #type (x: GLint, y: GLint, width: GLsizei, height: GLsizei, format: GLenum, type: GLenum, pixels: *void) #c_call;
glReadBuffer:  #type (src: GLenum) #c_call;
glDrawBuffer:  #type (buf: GLenum) #c_call;
glFinish:      #type () #c_call;
glFlush:       #type () #c_call;
glGetError:    #type () -> GLenum #c_call;
glGetIntegerv: #type (pname: GLenum, data: *GLint) #c_call;
glGetString:   #type (name: GLenum) -> *u8 #c_call;

// State enable/disable, blend, scissor, pixel store
glEnable:      #type (cap: GLenum) #c_call;
glDisable:     #type (cap: GLenum) #c_call;
glBlendFunc:   #type (sfactor: GLenum, dfactor: GLenum) #c_call;
glScissor:     #type (x: GLint, y: GLint, width: GLsizei, height: GLsizei) #c_call;
glPixelStorei: #type (pname: GLenum, param: GLint) #c_call;

// Textures
glGenTextures:    #type (n: GLsizei, textures: *GLuint) #c_call;
glDeleteTextures: #type (n: GLsizei, textures: *GLuint) #c_call;
glBindTexture:    #type (target: GLenum, texture: GLuint) #c_call;
glActiveTexture:  #type (texture: GLenum) #c_call;
glTexImage2D:     #type (target: GLenum, level: GLint, internalformat: GLint, width: GLsizei, height: GLsizei, border: GLint, format: GLenum, type: GLenum, pixels: *void) #c_call;
glTexParameteri:  #type (target: GLenum, pname: GLenum, param: GLint) #c_call;
glTexParameterf:  #type (target: GLenum, pname: GLenum, param: GLfloat) #c_call;
glEGLImageTargetTexture2DOES: #type (target: GLenum, image: GLeglImageOES) #c_call;

// Framebuffer objects
glGenFramebuffers:        #type (n: GLsizei, framebuffers: *GLuint) #c_call;
glDeleteFramebuffers:     #type (n: GLsizei, framebuffers: *GLuint) #c_call;
glBindFramebuffer:        #type (target: GLenum, framebuffer: GLuint) #c_call;
glFramebufferTexture2D:   #type (target: GLenum, attachment: GLenum, textarget: GLenum, texture: GLuint, level: GLint) #c_call;
glCheckFramebufferStatus: #type (target: GLenum) -> GLenum #c_call;

// Shaders / programs (Task 8)
glCreateShader:      #type (shaderType: GLenum) -> GLuint #c_call;
glDeleteShader:      #type (shader: GLuint) #c_call;
glShaderSource:      #type (shader: GLuint, count: GLsizei, strings: **GLchar, lengths: *GLint) #c_call;
glCompileShader:     #type (shader: GLuint) #c_call;
glGetShaderiv:       #type (shader: GLuint, pname: GLenum, params: *GLint) #c_call;
glGetShaderInfoLog:  #type (shader: GLuint, maxLength: GLsizei, length: *GLsizei, infoLog: *GLchar) #c_call;
glCreateProgram:     #type () -> GLuint #c_call;
glDeleteProgram:     #type (program: GLuint) #c_call;
glAttachShader:      #type (program: GLuint, shader: GLuint) #c_call;
glLinkProgram:       #type (program: GLuint) #c_call;
glGetProgramiv:      #type (program: GLuint, pname: GLenum, params: *GLint) #c_call;
glGetProgramInfoLog: #type (program: GLuint, maxLength: GLsizei, length: *GLsizei, infoLog: *GLchar) #c_call;
glUseProgram:         #type (program: GLuint) #c_call;
glGetUniformLocation: #type (program: GLuint, name: *GLchar) -> GLint #c_call;
glGetAttribLocation:  #type (program: GLuint, name: *GLchar) -> GLint #c_call;
glUniform1f:          #type (location: GLint, v0: GLfloat) #c_call;
glUniform1i:          #type (location: GLint, v0: GLint) #c_call;
glUniformMatrix4fv:   #type (location: GLint, count: GLsizei, transpose: GLboolean, value: *GLfloat) #c_call;

// Buffer objects (Task 8)
glGenBuffers:    #type (n: GLsizei, buffers: *GLuint) #c_call;
glDeleteBuffers: #type (n: GLsizei, buffers: *GLuint) #c_call;
glBindBuffer:    #type (target: GLenum, buffer: GLuint) #c_call;
glBufferData:    #type (target: GLenum, size: GLsizeiptr, data: *void, usage: GLenum) #c_call;
glMapBuffer:     #type (target: GLenum, access: GLenum) -> *void #c_call;
glMapBufferRange:#type (target: GLenum, offset: GLintptr, length: GLsizeiptr, access: GLbitfield) -> *void #c_call;
glUnmapBuffer:   #type (target: GLenum) -> GLboolean #c_call;

// Vertex array objects (Task 8)
glGenVertexArrays:          #type (n: GLsizei, arrays: *GLuint) #c_call;
glDeleteVertexArrays:       #type (n: GLsizei, arrays: *GLuint) #c_call;
glBindVertexArray:          #type (array: GLuint) #c_call;
glVertexAttribPointer:      #type (index: GLuint, size: GLint, type: GLenum, normalized: GLboolean, stride: GLsizei, pointer: *void) #c_call;
glEnableVertexAttribArray:  #type (index: GLuint) #c_call;
glDisableVertexAttribArray: #type (index: GLuint) #c_call;

// Framebuffer blit
glBlitFramebuffer: #type (srcX0: GLint, srcY0: GLint, srcX1: GLint, srcY1: GLint, dstX0: GLint, dstY0: GLint, dstX1: GLint, dstY1: GLint, mask: GLbitfield, filter: GLenum) #c_call;

// Fence sync (used by Simp gl_screenshot fast path)
glFenceSync:      #type (condition: GLenum, flags: GLbitfield) -> GLsync #c_call;
glClientWaitSync: #type (sync: GLsync, flags: GLbitfield, timeout: GLuint64) -> GLenum #c_call;

// Draw calls
glDrawArrays: #type (mode: GLenum, first: GLint, count: GLsizei) #c_call;
