declare i32 @puts(ptr)

define i32 @verify_args(i32 %argc, ptr %argument) {
entry:
  %argc-ok = icmp eq i32 %argc, 2
  %first-byte = load i8, ptr %argument
  %argument-ok = icmp eq i8 %first-byte, 104
  %ok = and i1 %argc-ok, %argument-ok
  br i1 %ok, label %success, label %failure

success:
  %ignored = call i32 @puts(ptr %argument)
  ret i32 0

failure:
  ret i32 65
}
