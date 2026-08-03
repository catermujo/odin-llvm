define i32 @main(i32 %argc, ptr %argv) {
entry:
  %and = and i32 %argc, 1
  %tobool = icmp eq i32 %and, 0
  br i1 %tobool, label %if.end, label %if.then

if.then:
  %call = tail call i32 @foo()
  br label %return

if.end:
  %call1 = tail call i32 @bar()
  br label %return

return:
  %retval.0 = phi i32 [ %call, %if.then ], [ %call1, %if.end ]
  ret i32 %retval.0
}

declare i32 @foo()
declare i32 @bar()
