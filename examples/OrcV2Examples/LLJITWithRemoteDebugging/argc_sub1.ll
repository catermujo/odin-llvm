define i32 @sub1(i32 %0) !dbg !4 {
  %2 = add i32 %0, -1, !dbg !8
  ret i32 %2, !dbg !9
}

define i32 @main(i32 %0, ptr %1) !dbg !10 {
  %3 = call i32 @sub1(i32 %0), !dbg !14
  ret i32 %3, !dbg !15
}

!llvm.module.flags = !{!0, !1}
!llvm.dbg.cu = !{!2}

!0 = !{i32 2, !"Dwarf Version", i32 4}
!1 = !{i32 2, !"Debug Info Version", i32 3}
!2 = distinct !DICompileUnit(language: DW_LANG_C99, file: !3, producer: "clang", emissionKind: FullDebug)
!3 = !DIFile(filename: "argc_sub1.c", directory: ".")
!4 = distinct !DISubprogram(name: "sub1", scope: !3, file: !3, line: 1, type: !5, scopeLine: 1, spFlags: DISPFlagDefinition, unit: !2)
!5 = !DISubroutineType(types: !6)
!6 = !{!7, !7}
!7 = !DIBasicType(name: "int", size: 32, encoding: DW_ATE_signed)
!8 = !DILocation(line: 1, column: 26, scope: !4)
!9 = !DILocation(line: 1, column: 19, scope: !4)
!10 = distinct !DISubprogram(name: "main", scope: !3, file: !3, line: 2, type: !11, scopeLine: 2, spFlags: DISPFlagDefinition, unit: !2)
!11 = !DISubroutineType(types: !12)
!12 = !{!7, !7, !13}
!13 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !16, size: 64)
!14 = !DILocation(line: 2, column: 42, scope: !10)
!15 = !DILocation(line: 2, column: 35, scope: !10)
!16 = !DIDerivedType(tag: DW_TAG_pointer_type, baseType: !17, size: 64)
!17 = !DIBasicType(name: "char", size: 8, encoding: DW_ATE_signed_char)
