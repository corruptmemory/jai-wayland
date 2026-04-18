// GL types — sizes match the standard glcorearb.h for x86_64 Linux.

GLenum     :: u32;
GLboolean  :: u8;
GLbitfield :: u32;
GLbyte     :: s8;
GLshort    :: s16;
GLint      :: s32;
GLuint     :: u32;
GLsizei    :: s32;
GLfloat    :: float32;
GLdouble   :: float64;
GLchar     :: u8;
GLintptr   :: s64;   // intptr_t on x86_64 Linux
GLsizeiptr :: s64;

// --- Boolean constants ---
GL_FALSE :: 0;
GL_TRUE  :: 1;

// --- Buffer clear bits ---
GL_COLOR_BUFFER_BIT   :: 0x00004000;
GL_DEPTH_BUFFER_BIT   :: 0x00000100;
GL_STENCIL_BUFFER_BIT :: 0x00000400;

// --- Primitive types ---
GL_TRIANGLES :: 0x0004;

// --- Data types ---
GL_UNSIGNED_BYTE :: 0x1401;
GL_FLOAT         :: 0x1406;

// --- Pixel formats ---
GL_RGBA  :: 0x1908;
GL_RGBA8 :: 0x8058;

// --- Textures ---
GL_TEXTURE_2D          :: 0x0DE1;
GL_TEXTURE_MIN_FILTER  :: 0x2801;
GL_TEXTURE_MAG_FILTER  :: 0x2800;
GL_NEAREST             :: 0x2600;
GL_LINEAR              :: 0x2601;

// --- Framebuffer objects ---
GL_FRAMEBUFFER             :: 0x8D40;
GL_COLOR_ATTACHMENT0       :: 0x8CE0;
GL_FRAMEBUFFER_COMPLETE    :: 0x8CD5;

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

// --- Errors ---
GL_NO_ERROR :: 0;

// --- Function pointers ---
// All null until gl_load() populates them. Casting xx on the result of
// get_proc_address keeps each declaration one line.

// Viewport / clear / read
glViewport:    #type (x: GLint, y: GLint, width: GLsizei, height: GLsizei) #c_call;
glClearColor:  #type (r: GLfloat, g: GLfloat, b: GLfloat, a: GLfloat) #c_call;
glClear:       #type (mask: GLbitfield) #c_call;
glReadPixels:  #type (x: GLint, y: GLint, width: GLsizei, height: GLsizei, format: GLenum, type: GLenum, pixels: *void) #c_call;
glFinish:      #type () #c_call;
glFlush:       #type () #c_call;
glGetError:    #type () -> GLenum #c_call;
glGetIntegerv: #type (pname: GLenum, data: *GLint) #c_call;
glGetString:   #type (name: GLenum) -> *u8 #c_call;

// Textures
glGenTextures:    #type (n: GLsizei, textures: *GLuint) #c_call;
glDeleteTextures: #type (n: GLsizei, textures: *GLuint) #c_call;
glBindTexture:    #type (target: GLenum, texture: GLuint) #c_call;
glTexImage2D:     #type (target: GLenum, level: GLint, internalformat: GLint, width: GLsizei, height: GLsizei, border: GLint, format: GLenum, type: GLenum, pixels: *void) #c_call;
glTexParameteri:  #type (target: GLenum, pname: GLenum, param: GLint) #c_call;

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
glUseProgram:        #type (program: GLuint) #c_call;
glGetUniformLocation:#type (program: GLuint, name: *GLchar) -> GLint #c_call;
glUniform1f:         #type (location: GLint, v0: GLfloat) #c_call;

// Buffer objects (Task 8)
glGenBuffers:    #type (n: GLsizei, buffers: *GLuint) #c_call;
glDeleteBuffers: #type (n: GLsizei, buffers: *GLuint) #c_call;
glBindBuffer:    #type (target: GLenum, buffer: GLuint) #c_call;
glBufferData:    #type (target: GLenum, size: GLsizeiptr, data: *void, usage: GLenum) #c_call;

// Vertex array objects (Task 8)
glGenVertexArrays:         #type (n: GLsizei, arrays: *GLuint) #c_call;
glDeleteVertexArrays:      #type (n: GLsizei, arrays: *GLuint) #c_call;
glBindVertexArray:         #type (array: GLuint) #c_call;
glVertexAttribPointer:     #type (index: GLuint, size: GLint, type: GLenum, normalized: GLboolean, stride: GLsizei, pointer: *void) #c_call;
glEnableVertexAttribArray: #type (index: GLuint) #c_call;

// Draw calls
glDrawArrays: #type (mode: GLenum, first: GLint, count: GLsizei) #c_call;
