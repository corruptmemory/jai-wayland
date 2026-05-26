// New file (not vendored — original to this project).
// Subsystem dispatch types and #add_context field for the vendored Simp
// backend. See docs/plans/2026-05-26-context-dispatch-stage1-design.md.

Simp_Op_Tag :: enum u32 {
    BACKEND_INIT;
    BACKEND_SET_RENDER_TARGET;
    BACKEND_RESIZE_RENDER_TARGET;
    SWAP_BUFFERS;
}

Backend_Init_Args                 :: struct { }
Backend_Set_Render_Target_Args    :: struct { }
Backend_Resize_Render_Target_Args :: struct {
    new_width:  s32;
    new_height: s32;
}
Swap_Buffers_Args :: struct {
    vsync: bool = true;
}

Simp_Op_Args :: union op: Simp_Op_Tag {
    .BACKEND_INIT                 ,, init                  : Backend_Init_Args;
    .BACKEND_SET_RENDER_TARGET    ,, set_render_target     : Backend_Set_Render_Target_Args;
    .BACKEND_RESIZE_RENDER_TARGET ,, resize_render_target  : Backend_Resize_Render_Target_Args;
    .SWAP_BUFFERS                 ,, swap_buffers          : Swap_Buffers_Args;
}

Simp_Backend_Dispatch :: #type (args: *Simp_Op_Args, info: *Window_Info) -> void;

#add_context simp_dispatch: Simp_Backend_Dispatch;
