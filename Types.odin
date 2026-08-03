#+build darwin, linux, windows

/*===-- llvm-c/Support.h - C Interface Types declarations ---------*- C -*-===*\
|*                                                                            *|
|* Part of the LLVM Project, under the Apache License v2.0 with LLVM          *|
|* Exceptions.                                                                *|
|* See https://llvm.org/LICENSE.txt for license information.                  *|
|* SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception                    *|
|*                                                                            *|
|*===----------------------------------------------------------------------===*|
|*                                                                            *|
|* This file defines types used by the C interface to LLVM.                   *|
|*                                                                            *|
\*===----------------------------------------------------------------------===*/
package llvm

/**
* @defgroup LLVMCSupportTypes Types and Enumerations
*
* @{
*/
Bool :: i32
OpaqueMemoryBuffer :: struct {}

/**
* Used to pass regions of memory through LLVM interfaces.
*
* @see llvm::MemoryBuffer
*/
MemoryBufferRef :: ^OpaqueMemoryBuffer
MemoryBuffer :: MemoryBufferRef
OpaqueContext :: struct {}

/**
* The top-level container for all LLVM global data. See the LLVMContext class.
*/
ContextRef :: ^OpaqueContext
Context :: ContextRef
OpaqueModule :: struct {}

/**
* The top-level container for all other LLVM Intermediate Representation (IR)
* objects.
*
* @see llvm::Module
*/
ModuleRef :: ^OpaqueModule
Module :: ModuleRef
OpaqueType :: struct {}

/**
* Each value in the LLVM IR has a type, an LLVMTypeRef.
*
* @see llvm::Type
*/
TypeRef :: ^OpaqueType
Type :: TypeRef
OpaqueValue :: struct {}

/**
* Represents an individual value in LLVM IR.
*
* This models llvm::Value.
*/
ValueRef :: ^OpaqueValue
Value :: ValueRef
ConstantFP :: ValueRef
OpaqueBasicBlock :: struct {}

/**
* Represents a basic block of instructions in LLVM IR.
*
* This models llvm::BasicBlock.
*/
BasicBlockRef :: ^OpaqueBasicBlock
BasicBlock :: BasicBlockRef
OpaqueMetadata :: struct {}

/**
* Represents an LLVM Metadata.
*
* This models llvm::Metadata.
*/
MetadataRef :: ^OpaqueMetadata
Metadata :: MetadataRef
OpaqueNamedMDNode :: struct {}

/**
* Represents an LLVM Named Metadata Node.
*
* This models llvm::NamedMDNode.
*/
NamedMDNodeRef :: ^OpaqueNamedMDNode
NamedMDNode :: NamedMDNodeRef
OpaqueValueMetadataEntry :: struct {}

/**
* Represents an entry in a Global Object's metadata attachments.
*
* This models std::pair<unsigned, MDNode *>
*/
ValueMetadataEntry :: OpaqueValueMetadataEntry
OpaqueBuilder :: struct {}

/**
* Represents an LLVM basic block builder.
*
* This models llvm::IRBuilder.
*/
BuilderRef :: ^OpaqueBuilder
Builder :: BuilderRef
IRBuilder :: BuilderRef
OpaqueDIBuilder :: struct {}

/**
* Represents an LLVM debug info builder.
*
* This models llvm::DIBuilder.
*/
DIBuilderRef :: ^OpaqueDIBuilder
DIBuilder :: DIBuilderRef
OpaqueModuleProvider :: struct {}

/**
* Interface used to provide a module to JIT or interpreter.
* This is now just a synonym for llvm::Module, but we have to keep using the
* different type to keep binary compatibility.
*/
ModuleProviderRef :: ^OpaqueModuleProvider
ModuleProvider :: ModuleProviderRef
OpaquePassManager :: struct {}

/** @see llvm::PassManagerBase */
PassManagerRef :: ^OpaquePassManager
PassManager :: PassManagerRef
OpaqueUse :: struct {}

/**
* Used to get the users and usees of a Value.
*
* @see llvm::Use */
UseRef :: ^OpaqueUse
Use :: UseRef
OpaqueOperandBundle :: struct {}

/**
* @see llvm::OperandBundleDef
*/
OperandBundleRef :: ^OpaqueOperandBundle
OperandBundle :: OperandBundleRef
OpaqueAttributeRef :: struct {}

/**
* Used to represent an attributes.
*
* @see llvm::Attribute
*/
AttributeRef :: ^OpaqueAttributeRef
OpaqueAttribute :: OpaqueAttributeRef
Attribute :: AttributeRef
OpaqueDiagnosticInfo :: struct {}

/**
* @see llvm::DiagnosticInfo
*/
DiagnosticInfoRef :: ^OpaqueDiagnosticInfo
DiagnosticInfo :: DiagnosticInfoRef
OpaqueComdat :: struct {}

/**
* @see llvm::Comdat
*/
ComdatRef :: ^OpaqueComdat
Comdat :: ComdatRef
OpaqueModuleFlagEntry :: struct {}

/**
* @see llvm::Module::ModuleFlagEntry
*/
ModuleFlagEntry :: OpaqueModuleFlagEntry
OpaqueJITEventListener :: struct {}

/**
* @see llvm::JITEventListener
*/
JITEventListenerRef :: ^OpaqueJITEventListener
JITEventListener :: JITEventListenerRef
OpaqueBinary :: struct {}

/**
* @see llvm::object::Binary
*/
BinaryRef :: ^OpaqueBinary
Binary :: BinaryRef
OpaqueDbgRecord :: struct {}

/**
* @see llvm::DbgRecord
*/
DbgRecordRef :: ^OpaqueDbgRecord
DbgRecord :: DbgRecordRef
