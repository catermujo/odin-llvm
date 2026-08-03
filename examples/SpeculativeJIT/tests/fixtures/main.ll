declare i32 @verify_args(i32, ptr)

define i32 @main(i32 %argc, ptr %argv) {
entry:
  %has-argument = icmp sgt i32 %argc, 1
  br i1 %has-argument, label %verify, label %missing

verify:
  %argument-slot = getelementptr ptr, ptr %argv, i64 1
  %argument = load ptr, ptr %argument-slot
  %status = call i32 @verify_args(i32 %argc, ptr %argument)
  ret i32 %status

missing:
  ret i32 64
}
