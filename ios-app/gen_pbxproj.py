#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 Trilium Mobile 原生 iOS App 的 Xcode 工程文件 project.pbxproj。
仅依赖标准库，在 Windows 上也能跑，用于产出可被 Mac 上 Xcode 直接打开的工程。

用法：
    python3 gen_pbxproj.py

会在 ios-app/TriliumMobile.xcodeproj/project.pbxproj 写入文件。
若增删了 Swift 源文件，重新跑本脚本即可同步。
"""
import os
import uuid

# 自动收集 TriliumMobile 目录下全部 Swift 源文件
_SWIFT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "TriliumMobile")
SWIFT_FILES = sorted(
    os.path.relpath(os.path.join(dp, name), _SWIFT_ROOT).replace("\\", "/")
    for dp, _dirs, names in os.walk(_SWIFT_ROOT)
    for name in names
    if name.endswith(".swift")
)

# 附加资源（如 mermaid.min.js）——进主 App 的 Resources phase，Bundle 里 Bundle.main 可读
RES_FILES = sorted(
    os.path.relpath(os.path.join(dp, name), _SWIFT_ROOT).replace("\\", "/")
    for dp, _dirs, names in os.walk(_SWIFT_ROOT)
    for name in names
    if name.endswith(".js")
)

# 分享扩展源文件（独立 target）
_EXT_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ShareExtension")
EXT_SWIFT_FILES = sorted(
    os.path.relpath(os.path.join(dp, name), _EXT_ROOT).replace("\\", "/")
    for dp, _dirs, names in os.walk(_EXT_ROOT)
    for name in names
    if name.endswith(".swift")
)

# 单元测试源文件（独立 test target，纯函数测试，不打包进 App）
_TEST_ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "TriliumMobileTests")
TEST_SWIFT_FILES = sorted(
    os.path.relpath(os.path.join(dp, name), _TEST_ROOT).replace("\\", "/")
    for dp, _dirs, names in os.walk(_TEST_ROOT)
    for name in names
    if name.endswith(".swift")
)

INFOPLIST = "Info.plist"
ASSET_CATALOG = "Assets.xcassets"


def oid(seed: str) -> str:
    h = uuid.uuid5(uuid.NAMESPACE_DNS, "triliummobile." + seed).hex
    return h[:24]


project_id = oid("PBXProject")
main_group_id = oid("MainGroup")
app_group_id = oid("TriliumMobileGroup")
target_id = oid("NativeTarget")
product_id = oid("Product.TriliumMobile.app")
sources_id = oid("SourcesBuildPhase")
frameworks_id = oid("FrameworksBuildPhase")
resources_id = oid("ResourcesBuildPhase")
proj_cl_id = oid("ProjConfigList")
target_cl_id = oid("TargetConfigList")
proj_dbg_id = oid("ProjDebug")
proj_rel_id = oid("ProjRelease")
tgt_dbg_id = oid("TargetDebug")
tgt_rel_id = oid("TargetRelease")

# 分享扩展 target
ext_target_id = oid("ExtNativeTarget")
ext_product_id = oid("Product.TriliumShare.appex")
ext_sources_id = oid("ExtSourcesBuildPhase")
ext_frameworks_id = oid("ExtFrameworksBuildPhase")
ext_resources_id = oid("ExtResourcesBuildPhase")
ext_group_id = oid("ShareExtensionGroup")
ext_cl_id = oid("ExtTargetConfigList")
ext_dbg_id = oid("ExtTargetDebug")
ext_rel_id = oid("ExtTargetRelease")
embed_id = oid("EmbedFoundationPhase")
ext_appex_build_id = oid("BuildFile.TriliumShare.appex")
ext_proxy_id = oid("ContainerItemProxy")
ext_dep_id = oid("TargetDependency")

# 单元测试 target
test_target_id = oid("TestNativeTarget")
test_product_id = oid("Product.TriliumMobileTests.xctest")
test_sources_id = oid("TestSourcesBuildPhase")
test_frameworks_id = oid("TestFrameworksBuildPhase")
test_group_id = oid("TriliumMobileTestsGroup")
test_cl_id = oid("TestTargetConfigList")
test_dbg_id = oid("TestTargetDebug")
test_rel_id = oid("TestTargetRelease")
test_dep_id = oid("TestTargetDependency")
test_proxy_id = oid("TestContainerItemProxy")

file_ref_ids = {}
build_file_ids = {}
for f in SWIFT_FILES:
    file_ref_ids[f] = oid("FileRef." + f)
    build_file_ids[f] = oid("BuildFile." + f)

ext_file_ref_ids = {}
ext_build_file_ids = {}
for f in EXT_SWIFT_FILES:
    ext_file_ref_ids[f] = oid("ExtFileRef." + f)
    ext_build_file_ids[f] = oid("ExtBuildFile." + f)

test_file_ref_ids = {}
test_build_file_ids = {}
for f in TEST_SWIFT_FILES:
    test_file_ref_ids[f] = oid("TestFileRef." + f)
    test_build_file_ids[f] = oid("TestBuildFile." + f)

res_ref_ids = {}
res_build_ids = {}
for f in RES_FILES:
    res_ref_ids[f] = oid("ResRef." + f)
    res_build_ids[f] = oid("ResBuild." + f)

assets_ref_id = oid("FileRef." + ASSET_CATALOG)
assets_build_id = oid("BuildFile." + ASSET_CATALOG)

# ---- PBXBuildFile ----
build_files = []
for f in SWIFT_FILES:
    name = os.path.basename(f)
    build_files.append(
        f'\t\t{build_file_ids[f]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ref_ids[f]} /* {name} */; }};\n'
    )
build_files_txt = "".join(build_files)
build_files_txt += (
    f'\t\t{assets_build_id} /* {ASSET_CATALOG} in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_ref_id} /* {ASSET_CATALOG} */; }};\n'
)
for f in RES_FILES:
    name = os.path.basename(f)
    build_files_txt += (
        f'\t\t{res_build_ids[f]} /* {name} in Resources */ = {{isa = PBXBuildFile; fileRef = {res_ref_ids[f]} /* {name} */; }};\n'
    )
# 分享扩展：源文件 BuildFile + appex 的 Embed BuildFile
for f in EXT_SWIFT_FILES:
    name = os.path.basename(f)
    build_files_txt += (
        f'\t\t{ext_build_file_ids[f]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ext_file_ref_ids[f]} /* {name} */; }};\n'
    )
build_files_txt += (
    f'\t\t{ext_appex_build_id} /* TriliumShare.appex in Embed Foundation */ = {{isa = PBXBuildFile; fileRef = {ext_product_id} /* TriliumShare.appex */; settings = {{ATTRIBUTES = (RemoveHeadersOnCopy, ); }}; }};\n'
)
# 单元测试：源文件 BuildFile
for f in TEST_SWIFT_FILES:
    name = os.path.basename(f)
    build_files_txt += (
        f'\t\t{test_build_file_ids[f]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {test_file_ref_ids[f]} /* {name} */; }};\n'
    )

# ---- PBXFileReference ----
file_refs = []
for f in SWIFT_FILES:
    name = os.path.basename(f)
    file_refs.append(
        f'\t\t{file_ref_ids[f]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = "<group>"; }};\n'
    )
file_refs.append(
    f'\t\t{product_id} /* TriliumMobile.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = TriliumMobile.app; sourceTree = BUILT_PRODUCTS_DIR; }};\n'
)
file_refs.append(
    f'\t\t{assets_ref_id} /* {ASSET_CATALOG} */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = {ASSET_CATALOG}; sourceTree = "<group>"; }};\n'
)
for f in RES_FILES:
    name = os.path.basename(f)
    file_refs.append(
        f'\t\t{res_ref_ids[f]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.javascript; path = {f}; sourceTree = "<group>"; }};\n'
    )
for f in EXT_SWIFT_FILES:
    name = os.path.basename(f)
    # FileRef path 相对于所在 PBXGroup（group 已带 path = ShareExtension），不能再拼前缀
    file_refs.append(
        f'\t\t{ext_file_ref_ids[f]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = "<group>"; }};\n'
    )
for f in TEST_SWIFT_FILES:
    name = os.path.basename(f)
    file_refs.append(
        f'\t\t{test_file_ref_ids[f]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {f}; sourceTree = "<group>"; }};\n'
    )
file_refs.append(
    f'\t\t{ext_product_id} /* TriliumShare.appex */ = {{isa = PBXFileReference; explicitFileType = "wrapper.app-extension"; includeInIndex = 0; path = TriliumShare.appex; sourceTree = BUILT_PRODUCTS_DIR; }};\n'
)
file_refs.append(
    f'\t\t{test_product_id} /* TriliumMobileTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = TriliumMobileTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};\n'
)
file_refs_txt = "".join(file_refs)

# ---- PBXGroup ----
group_children = ",\n".join(
    f"\t\t\t\t{file_ref_ids[f]} /* {os.path.basename(f)} */" for f in SWIFT_FILES
)
group_children += f",\n\t\t\t\t{assets_ref_id} /* {ASSET_CATALOG} */"
for f in RES_FILES:
    group_children += f",\n\t\t\t\t{res_ref_ids[f]} /* {os.path.basename(f)} */"
app_group = (
    f'\t\t{app_group_id} /* TriliumMobile */ = {{\n'
    f'\t\t\tisa = PBXGroup;\n'
    f'\t\t\tchildren = (\n{group_children},\n'
    f'\t\t\t);\n'
    f'\t\t\tpath = TriliumMobile;\n'
    f'\t\t\tsourceTree = "<group>";\n'
    f'\t\t}};\n'
)
ext_group_children = ",\n".join(
    f"\t\t\t\t{ext_file_ref_ids[f]} /* {os.path.basename(f)} */" for f in EXT_SWIFT_FILES
)
ext_group = (
    f'\t\t{ext_group_id} /* ShareExtension */ = {{\n'
    f'\t\t\tisa = PBXGroup;\n'
    f'\t\t\tchildren = (\n{ext_group_children},\n'
    f'\t\t\t);\n'
    f'\t\t\tpath = ShareExtension;\n'
    f'\t\t\tsourceTree = "<group>";\n'
    f'\t\t}};\n'
)
test_group_children = ",\n".join(
    f"\t\t\t\t{test_file_ref_ids[f]} /* {os.path.basename(f)} */" for f in TEST_SWIFT_FILES
)
test_group = (
    f'\t\t{test_group_id} /* TriliumMobileTests */ = {{\n'
    f'\t\t\tisa = PBXGroup;\n'
    f'\t\t\tchildren = (\n{test_group_children},\n'
    f'\t\t\t);\n'
    f'\t\t\tpath = TriliumMobileTests;\n'
    f'\t\t\tsourceTree = "<group>";\n'
    f'\t\t}};\n'
)
main_group = (
    f'\t\t{main_group_id} = {{\n'
    f'\t\t\tisa = PBXGroup;\n'
    f'\t\t\tchildren = (\n'
    f'\t\t\t\t{app_group_id} /* TriliumMobile */,\n'
    f'\t\t\t\t{ext_group_id} /* ShareExtension */,\n'
    f'\t\t\t\t{test_group_id} /* TriliumMobileTests */,\n'
    f'\t\t\t\t{product_id} /* TriliumMobile.app */,\n'
    f'\t\t\t\t{ext_product_id} /* TriliumShare.appex */,\n'
    f'\t\t\t\t{test_product_id} /* TriliumMobileTests.xctest */,\n'
    f'\t\t\t);\n'
    f'\t\t\tsourceTree = "<group>";\n'
    f'\t\t}};\n'
)
groups_txt = app_group + ext_group + test_group + main_group

# ---- PBXNativeTarget ----
target_txt = (
    f'\t\t{target_id} /* TriliumMobile */ = {{\n'
    f'\t\t\tisa = PBXNativeTarget;\n'
    f'\t\t\tbuildConfigurationList = {target_cl_id} /* Build configuration list for PBXNativeTarget "TriliumMobile" */;\n'
    f'\t\t\tbuildPhases = (\n'
    f'\t\t\t\t{sources_id} /* Sources */,\n'
    f'\t\t\t\t{frameworks_id} /* Frameworks */,\n'
    f'\t\t\t\t{resources_id} /* Resources */,\n'
    f'\t\t\t\t{embed_id} /* Embed Foundation */,\n'
    f'\t\t\t);\n'
    f'\t\t\tbuildRules = (\n'
    f'\t\t\t);\n'
    f'\t\t\tdependencies = (\n'
    f'\t\t\t\t{ext_dep_id} /* PBXTargetDependency */,\n'
    f'\t\t\t);\n'
    f'\t\t\tname = TriliumMobile;\n'
    f'\t\t\tproductName = TriliumMobile;\n'
    f'\t\t\tproductReference = {product_id} /* TriliumMobile.app */;\n'
    f'\t\t\tproductType = "com.apple.product-type.application";\n'
    f'\t\t}};\n'
)

ext_target_txt = (
    f'\t\t{ext_target_id} /* ShareExtension */ = {{\n'
    f'\t\t\tisa = PBXNativeTarget;\n'
    f'\t\t\tbuildConfigurationList = {ext_cl_id} /* Build configuration list for PBXNativeTarget "ShareExtension" */;\n'
    f'\t\t\tbuildPhases = (\n'
    f'\t\t\t\t{ext_sources_id} /* Sources */,\n'
    f'\t\t\t\t{ext_frameworks_id} /* Frameworks */,\n'
    f'\t\t\t\t{ext_resources_id} /* Resources */,\n'
    f'\t\t\t);\n'
    f'\t\t\tbuildRules = (\n'
    f'\t\t\t);\n'
    f'\t\t\tdependencies = (\n'
    f'\t\t\t);\n'
    f'\t\t\tname = ShareExtension;\n'
    f'\t\t\tproductName = ShareExtension;\n'
    f'\t\t\tproductReference = {ext_product_id} /* TriliumShare.appex */;\n'
    f'\t\t\tproductType = "com.apple.product-type.app-extension";\n'
    f'\t\t}};\n'
)

test_target_txt = (
    f'\t\t{test_target_id} /* TriliumMobileTests */ = {{\n'
    f'\t\t\tisa = PBXNativeTarget;\n'
    f'\t\t\tbuildConfigurationList = {test_cl_id} /* Build configuration list for PBXNativeTarget "TriliumMobileTests" */;\n'
    f'\t\t\tbuildPhases = (\n'
    f'\t\t\t\t{test_sources_id} /* Sources */,\n'
    f'\t\t\t\t{test_frameworks_id} /* Frameworks */,\n'
    f'\t\t\t);\n'
    f'\t\t\tbuildRules = (\n'
    f'\t\t\t);\n'
    f'\t\t\tdependencies = (\n'
    f'\t\t\t\t{test_dep_id} /* PBXTargetDependency */,\n'
    f'\t\t\t);\n'
    f'\t\t\tname = TriliumMobileTests;\n'
    f'\t\t\tproductName = TriliumMobileTests;\n'
    f'\t\t\tproductReference = {test_product_id} /* TriliumMobileTests.xctest */;\n'
    f'\t\t\tproductType = "com.apple.product-type.bundle.unit-test";\n'
    f'\t\t}};\n'
)

# ---- PBXProject ----
project_txt = (
    f'\t\t{project_id} /* Project object */ = {{\n'
    f'\t\t\tisa = PBXProject;\n'
    f'\t\t\tattributes = {{\n'
    f'\t\t\t\tBuildIndependentTargetsInParallel = 1;\n'
    f'\t\t\t\tLastSwiftUpdateCheck = 1500;\n'
    f'\t\t\t\tLastUpgradeCheck = 1500;\n'
    f'\t\t\t\tTargetAttributes = {{\n'
    f'\t\t\t\t\t{target_id} = {{\n'
    f'\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n'
    f'\t\t\t\t\t}};\n'
    f'\t\t\t\t\t{ext_target_id} = {{\n'
    f'\t\t\t\t\t\tCreatedOnToolsVersion = 15.0;\n'
    f'\t\t\t\t\t}};\n'
    f'\t\t\t\t}};\n'
    f'\t\t\t}};\n'
    f'\t\t\tbuildConfigurationList = {proj_cl_id} /* Build configuration list for PBXProject "TriliumMobile" */;\n'
    f'\t\t\tcompatibilityVersion = "Xcode 14.0";\n'
    f'\t\t\tdevelopmentRegion = en;\n'
    f'\t\t\thasScannedForEncodings = 0;\n'
    f'\t\t\tknownRegions = (\n'
    f'\t\t\t\ten,\n'
    f'\t\t\t\tBase,\n'
    f'\t\t\t);\n'
    f'\t\t\tmainGroup = {main_group_id};\n'
    f'\t\t\tproductRefGroup = {main_group_id} /* TriliumMobile */;\n'
    f'\t\t\tprojectDirPath = "";\n'
    f'\t\t\tprojectRoot = "";\n'
    f'\t\t\ttargets = (\n'
    f'\t\t\t\t{target_id} /* TriliumMobile */,\n'
    f'\t\t\t\t{ext_target_id} /* ShareExtension */,\n'
    f'\t\t\t\t{test_target_id} /* TriliumMobileTests */,\n'
    f'\t\t\t);\n'
    f'\t\t}};\n'
)

# ---- PBXSourcesBuildPhase ----
sources_children = ",\n".join(
    f"\t\t\t\t{build_file_ids[f]} /* {os.path.basename(f)} in Sources */" for f in SWIFT_FILES
)
sources_txt = (
    f'\t\t{sources_id} /* Sources */ = {{\n'
    f'\t\t\tisa = PBXSourcesBuildPhase;\n'
    f'\t\t\tbuildActionMask = 2147483647;\n'
    f'\t\t\tfiles = (\n{sources_children},\n'
    f'\t\t\t);\n'
    f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
    f'\t\t}};\n'
)

ext_sources_children = ",\n".join(
    f"\t\t\t\t{ext_build_file_ids[f]} /* {os.path.basename(f)} in Sources */" for f in EXT_SWIFT_FILES
)
ext_sources_txt = (
    f'\t\t{ext_sources_id} /* Sources */ = {{\n'
    f'\t\t\tisa = PBXSourcesBuildPhase;\n'
    f'\t\t\tbuildActionMask = 2147483647;\n'
    f'\t\t\tfiles = (\n{ext_sources_children},\n'
    f'\t\t\t);\n'
    f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
    f'\t\t}};\n'
)

test_sources_children = ",\n".join(
    f"\t\t\t\t{test_build_file_ids[f]} /* {os.path.basename(f)} in Sources */" for f in TEST_SWIFT_FILES
)
test_sources_txt = (
    f'\t\t{test_sources_id} /* Sources */ = {{\n'
    f'\t\t\tisa = PBXSourcesBuildPhase;\n'
    f'\t\t\tbuildActionMask = 2147483647;\n'
    f'\t\t\tfiles = (\n{test_sources_children},\n'
    f'\t\t\t);\n'
    f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
    f'\t\t}};\n'
)

# Embed Foundation：把 .appex 塞进宿主 App（PlugIns/）
embed_txt = (
    f'\t\t{embed_id} /* Embed Foundation */ = {{\n'
    f'\t\t\tisa = PBXCopyFilesBuildPhase;\n'
    f'\t\t\tbuildActionMask = 2147483647;\n'
    f'\t\t\tdstPath = "";\n'
    f'\t\t\tdstSubfolderSpec = 13;\n'
    f'\t\t\tfiles = (\n'
    f'\t\t\t\t{ext_appex_build_id} /* TriliumShare.appex in Embed Foundation */,\n'
    f'\t\t\t);\n'
    f'\t\t\tname = "Embed Foundation";\n'
    f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
    f'\t\t}};\n'
)

# ---- Frameworks / Resources ----
frameworks_txt = (
    f'\t\t{frameworks_id} /* Frameworks */ = {{\n'
    f'\t\t\tisa = PBXFrameworksBuildPhase;\n'
    f'\t\t\tbuildActionMask = 2147483647;\n'
    f'\t\t\tfiles = (\n'
    f'\t\t\t);\n'
    f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
    f'\t\t}};\n'
)
test_frameworks_txt = (
    f'\t\t{test_frameworks_id} /* Frameworks */ = {{\n'
    f'\t\t\tisa = PBXFrameworksBuildPhase;\n'
    f'\t\t\tbuildActionMask = 2147483647;\n'
    f'\t\t\tfiles = (\n'
    f'\t\t\t);\n'
    f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
    f'\t\t}};\n'
)
resources_children = "".join(
    f"\t\t\t\t{res_build_ids[f]} /* {os.path.basename(f)} in Resources */,\n" for f in RES_FILES
)
resources_txt = (
    f'\t\t{resources_id} /* Resources */ = {{\n'
    f'\t\t\tisa = PBXResourcesBuildPhase;\n'
    f'\t\t\tbuildActionMask = 2147483647;\n'
    f'\t\t\tfiles = (\n'
    f'\t\t\t\t{assets_build_id} /* {ASSET_CATALOG} in Resources */,\n'
    f'{resources_children}'
    f'\t\t\t);\n'
    f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
    f'\t\t}};\n'
)
ext_resources_txt = (
    f'\t\t{ext_resources_id} /* Resources */ = {{\n'
    f'\t\t\tisa = PBXResourcesBuildPhase;\n'
    f'\t\t\tbuildActionMask = 2147483647;\n'
    f'\t\t\tfiles = (\n'
    f'\t\t\t);\n'
    f'\t\t\trunOnlyForDeploymentPostprocessing = 0;\n'
    f'\t\t}};\n'
)

# ---- XCBuildConfiguration ----
proj_debug = (
    f'\t\t{proj_dbg_id} /* Debug */ = {{\n'
    f'\t\t\tisa = XCBuildConfiguration;\n'
    f'\t\t\tbuildSettings = {{\n'
    f'\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;\n'
    f'\t\t\t\tCLANG_ANALYZER_NONNULL = YES;\n'
    f'\t\t\t\tCOPY_PHASE_STRIP = NO;\n'
    f'\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;\n'
    f'\t\t\t\tENABLE_TESTABILITY = YES;\n'
    f'\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;\n'
    f'\t\t\t\tGCC_OPTIMIZATION_LEVEL = 0;\n'
    f'\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.1;\n'
    f'\t\t\t\tMTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;\n'
    f'\t\t\t\tONLY_ACTIVE_ARCH = YES;\n'
    f'\t\t\t\tSDKROOT = iphoneos;\n'
    f'\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";\n'
    f'\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = "-Onone";\n'
    f'\t\t\t}};\n'
    f'\t\t\tname = Debug;\n'
    f'\t\t}};\n'
)
proj_release = (
    f'\t\t{proj_rel_id} /* Release */ = {{\n'
    f'\t\t\tisa = XCBuildConfiguration;\n'
    f'\t\t\tbuildSettings = {{\n'
    f'\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;\n'
    f'\t\t\t\tCLANG_ANALYZER_NONNULL = YES;\n'
    f'\t\t\t\tCOPY_PHASE_STRIP = NO;\n'
    f'\t\t\t\tENABLE_NS_ASSERTIONS = NO;\n'
    f'\t\t\t\tENABLE_STRICT_OBJC_MSGSEND = YES;\n'
    f'\t\t\t\tGCC_C_LANGUAGE_STANDARD = gnu17;\n'
    f'\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.1;\n'
    f'\t\t\t\tMTL_ENABLE_DEBUG_INFO = NO;\n'
    f'\t\t\t\tSDKROOT = iphoneos;\n'
    f'\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;\n'
    f'\t\t\t\tVALIDATE_PRODUCT = YES;\n'
    f'\t\t\t}};\n'
    f'\t\t\tname = Release;\n'
    f'\t\t}};\n'
)

target_debug = (
    f'\t\t{tgt_dbg_id} /* Debug */ = {{\n'
    f'\t\t\tisa = XCBuildConfiguration;\n'
    f'\t\t\tbuildSettings = {{\n'
    f'\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;\n'
    f'\t\t\t\tCODE_SIGN_ENTITLEMENTS = TriliumMobile/TriliumMobile.entitlements;\n'
    f'\t\t\t\tCODE_SIGN_STYLE = Automatic;\n'
    f'\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n'
    f'\t\t\t\tDEVELOPMENT_TEAM = "";\n'
    f'\t\t\t\tENABLE_PREVIEWS = YES;\n'
    f'\t\t\t\tGENERATE_INFOPLIST_FILE = NO;\n'
    f'\t\t\t\tINFOPLIST_FILE = TriliumMobile/Info.plist;\n'
    f'\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.1;\n'
    f'\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n'
    f'\t\t\t\t\t"$(inherited)",\n'
    f'\t\t\t\t\t"@executable_path/Frameworks",\n'
    f'\t\t\t\t);\n'
    f'\t\t\t\tMARKETING_VERSION = 1.0.0;\n'
    f'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.hhxxc.trilium;\n'
    f'\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";\n'
    f'\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;\n'
    f'\t\t\t\tSWIFT_VERSION = 5.0;\n'
    f'\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";\n'
    f'\t\t\t}};\n'
    f'\t\t\tname = Debug;\n'
    f'\t\t}};\n'
)
target_release = (
    f'\t\t{tgt_rel_id} /* Release */ = {{\n'
    f'\t\t\tisa = XCBuildConfiguration;\n'
    f'\t\t\tbuildSettings = {{\n'
    f'\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;\n'
    f'\t\t\t\tCODE_SIGN_ENTITLEMENTS = TriliumMobile/TriliumMobile.entitlements;\n'
    f'\t\t\t\tCODE_SIGN_STYLE = Automatic;\n'
    f'\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n'
    f'\t\t\t\tDEVELOPMENT_TEAM = "";\n'
    f'\t\t\t\tENABLE_PREVIEWS = YES;\n'
    f'\t\t\t\tGENERATE_INFOPLIST_FILE = NO;\n'
    f'\t\t\t\tINFOPLIST_FILE = TriliumMobile/Info.plist;\n'
    f'\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.1;\n'
    f'\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n'
    f'\t\t\t\t\t"$(inherited)",\n'
    f'\t\t\t\t\t"@executable_path/Frameworks",\n'
    f'\t\t\t\t);\n'
    f'\t\t\t\tMARKETING_VERSION = 1.0.0;\n'
    f'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.hhxxc.trilium;\n'
    f'\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";\n'
    f'\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;\n'
    f'\t\t\t\tSWIFT_VERSION = 5.0;\n'
    f'\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";\n'
    f'\t\t\t}};\n'
    f'\t\t\tname = Release;\n'
    f'\t\t}};\n'
)

configs_txt = proj_debug + proj_release + target_debug + target_release

# 分享扩展 target 配置（无 entitlements：URL scheme 方案；SKIP_INSTALL 必须 YES）
ext_tgt_debug = (
    f'\t\t{ext_dbg_id} /* Debug */ = {{\n'
    f'\t\t\tisa = XCBuildConfiguration;\n'
    f'\t\t\tbuildSettings = {{\n'
    f'\t\t\t\tCODE_SIGN_STYLE = Automatic;\n'
    f'\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n'
    f'\t\t\t\tDEVELOPMENT_TEAM = "";\n'
    f'\t\t\t\tGENERATE_INFOPLIST_FILE = NO;\n'
    f'\t\t\t\tINFOPLIST_FILE = ShareExtension/Info.plist;\n'
    f'\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.1;\n'
    f'\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n'
    f'\t\t\t\t\t"$(inherited)",\n'
    f'\t\t\t\t\t"@executable_path/Frameworks",\n'
    f'\t\t\t\t\t"@executable_path/../../Frameworks",\n'
    f'\t\t\t\t);\n'
    f'\t\t\t\tMARKETING_VERSION = 1.0.0;\n'
    f'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.hhxxc.trilium.ShareExtension;\n'
    # ⚠️ 必须是 TriliumShare（与 Embed phase 引用的 TriliumShare.appex 一致）。
    #   写 $(TARGET_NAME) 会产出 ShareExtension.appex → 嵌入静默跳过 → 打包报「分享扩展未嵌入」
    f'\t\t\t\tPRODUCT_NAME = TriliumShare;\n'
    f'\t\t\t\tSKIP_INSTALL = YES;\n'
    f'\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;\n'
    f'\t\t\t\tSWIFT_VERSION = 5.0;\n'
    f'\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";\n'
    f'\t\t\t}};\n'
    f'\t\t\tname = Debug;\n'
    f'\t\t}};\n'
)
ext_tgt_release = (
    f'\t\t{ext_rel_id} /* Release */ = {{\n'
    f'\t\t\tisa = XCBuildConfiguration;\n'
    f'\t\t\tbuildSettings = {{\n'
    f'\t\t\t\tCODE_SIGN_STYLE = Automatic;\n'
    f'\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n'
    f'\t\t\t\tDEVELOPMENT_TEAM = "";\n'
    f'\t\t\t\tGENERATE_INFOPLIST_FILE = NO;\n'
    f'\t\t\t\tINFOPLIST_FILE = ShareExtension/Info.plist;\n'
    f'\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.1;\n'
    f'\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n'
    f'\t\t\t\t\t"$(inherited)",\n'
    f'\t\t\t\t\t"@executable_path/Frameworks",\n'
    f'\t\t\t\t\t"@executable_path/../../Frameworks",\n'
    f'\t\t\t\t);\n'
    f'\t\t\t\tMARKETING_VERSION = 1.0.0;\n'
    f'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.hhxxc.trilium.ShareExtension;\n'
    # ⚠️ 必须是 TriliumShare（与 Embed phase 引用的 TriliumShare.appex 一致）。
    #   写 $(TARGET_NAME) 会产出 ShareExtension.appex → 嵌入静默跳过 → 打包报「分享扩展未嵌入」
    f'\t\t\t\tPRODUCT_NAME = TriliumShare;\n'
    f'\t\t\t\tSKIP_INSTALL = YES;\n'
    f'\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;\n'
    f'\t\t\t\tSWIFT_VERSION = 5.0;\n'
    f'\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";\n'
    f'\t\t\t}};\n'
    f'\t\t\tname = Release;\n'
    f'\t\t}};\n'
)
configs_txt += ext_tgt_debug + ext_tgt_release

# 单元测试 target 配置（host 是 TriliumMobile.app；无 entitlements）
test_tgt_debug = (
    f'\t\t{test_dbg_id} /* Debug */ = {{\n'
    f'\t\t\tisa = XCBuildConfiguration;\n'
    f'\t\t\tbuildSettings = {{\n'
    f'\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";\n'
    f'\t\t\t\tCODE_SIGN_STYLE = Automatic;\n'
    f'\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n'
    f'\t\t\t\tDEVELOPMENT_TEAM = "";\n'
    f'\t\t\t\tGENERATE_INFOPLIST_FILE = YES;\n'
    f'\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.1;\n'
    f'\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n'
    f'\t\t\t\t\t"$(inherited)",\n'
    f'\t\t\t\t\t"@executable_path/Frameworks",\n'
    f'\t\t\t\t\t"@loader_path/Frameworks",\n'
    f'\t\t\t\t);\n'
    f'\t\t\t\tMARKETING_VERSION = 1.0.0;\n'
    f'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.hhxxc.trilium.tests;\n'
    f'\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";\n'
    f'\t\t\t\tSWIFT_VERSION = 5.0;\n'
    f'\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";\n'
    f'\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/TriliumMobile.app/TriliumMobile";\n'
    f'\t\t\t}};\n'
    f'\t\t\tname = Debug;\n'
    f'\t\t}};\n'
)
test_tgt_release = (
    f'\t\t{test_rel_id} /* Release */ = {{\n'
    f'\t\t\tisa = XCBuildConfiguration;\n'
    f'\t\t\tbuildSettings = {{\n'
    f'\t\t\t\tBUNDLE_LOADER = "$(TEST_HOST)";\n'
    f'\t\t\t\tCODE_SIGN_STYLE = Automatic;\n'
    f'\t\t\t\tCURRENT_PROJECT_VERSION = 1;\n'
    f'\t\t\t\tDEVELOPMENT_TEAM = "";\n'
    f'\t\t\t\tGENERATE_INFOPLIST_FILE = YES;\n'
    f'\t\t\t\tIPHONEOS_DEPLOYMENT_TARGET = 15.1;\n'
    f'\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\n'
    f'\t\t\t\t\t"$(inherited)",\n'
    f'\t\t\t\t\t"@executable_path/Frameworks",\n'
    f'\t\t\t\t\t"@loader_path/Frameworks",\n'
    f'\t\t\t\t);\n'
    f'\t\t\t\tMARKETING_VERSION = 1.0.0;\n'
    f'\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.hhxxc.trilium.tests;\n'
    f'\t\t\t\tPRODUCT_NAME = "$(TARGET_NAME)";\n'
    f'\t\t\t\tSWIFT_VERSION = 5.0;\n'
    f'\t\t\t\tTARGETED_DEVICE_FAMILY = "1,2";\n'
    f'\t\t\t\tTEST_HOST = "$(BUILT_PRODUCTS_DIR)/TriliumMobile.app/TriliumMobile";\n'
    f'\t\t\t}};\n'
    f'\t\t\tname = Release;\n'
    f'\t\t}};\n'
)
configs_txt += test_tgt_debug + test_tgt_release

# ---- XCConfigurationList ----
lists_txt = (
    f'\t\t{proj_cl_id} /* Build configuration list for PBXProject "TriliumMobile" */ = {{\n'
    f'\t\t\tisa = XCConfigurationList;\n'
    f'\t\t\tbuildConfigurations = (\n'
    f'\t\t\t\t{proj_dbg_id} /* Debug */,\n'
    f'\t\t\t\t{proj_rel_id} /* Release */,\n'
    f'\t\t\t);\n'
    f'\t\t\tdefaultConfigurationIsVisible = 0;\n'
    f'\t\t\tdefaultConfigurationName = Release;\n'
    f'\t\t}};\n'
    f'\t\t{target_cl_id} /* Build configuration list for PBXNativeTarget "TriliumMobile" */ = {{\n'
    f'\t\t\tisa = XCConfigurationList;\n'
    f'\t\t\tbuildConfigurations = (\n'
    f'\t\t\t\t{tgt_dbg_id} /* Debug */,\n'
    f'\t\t\t\t{tgt_rel_id} /* Release */,\n'
    f'\t\t\t);\n'
    f'\t\t\tdefaultConfigurationIsVisible = 0;\n'
    f'\t\t\tdefaultConfigurationName = Release;\n'
    f'\t\t}};\n'
    f'\t\t{ext_cl_id} /* Build configuration list for PBXNativeTarget "ShareExtension" */ = {{\n'
    f'\t\t\tisa = XCConfigurationList;\n'
    f'\t\t\tbuildConfigurations = (\n'
    f'\t\t\t\t{ext_dbg_id} /* Debug */,\n'
    f'\t\t\t\t{ext_rel_id} /* Release */,\n'
    f'\t\t\t);\n'
    f'\t\t\tdefaultConfigurationIsVisible = 0;\n'
    f'\t\t\tdefaultConfigurationName = Release;\n'
    f'\t\t}};\n'
    f'\t\t{test_cl_id} /* Build configuration list for PBXNativeTarget "TriliumMobileTests" */ = {{\n'
    f'\t\t\tisa = XCConfigurationList;\n'
    f'\t\t\tbuildConfigurations = (\n'
    f'\t\t\t\t{test_dbg_id} /* Debug */,\n'
    f'\t\t\t\t{test_rel_id} /* Release */,\n'
    f'\t\t\t);\n'
    f'\t\t\tdefaultConfigurationIsVisible = 0;\n'
    f'\t\t\tdefaultConfigurationName = Release;\n'
    f'\t\t}};\n'
)

pbxproj = (
    '// !$*UTF8*$!\n'
    '{\n'
    '\tarchiveVersion = 1;\n'
    '\tclasses = {\n'
    '\t};\n'
    '\tobjectVersion = 56;\n'
    '\tobjects = {\n\n'
    '/* Begin PBXBuildFile section */\n'
    f'{build_files_txt}'
    '/* End PBXBuildFile section */\n\n'
    '/* Begin PBXContainerItemProxy section */\n'
    f'\t\t{ext_proxy_id} /* PBXContainerItemProxy */ = {{\n'
    f'\t\t\tisa = PBXContainerItemProxy;\n'
    f'\t\t\tcontainerPortal = {project_id} /* Project object */;\n'
    f'\t\t\tproxyType = 1;\n'
    f'\t\t\tremoteGlobalIDString = {ext_target_id};\n'
    f'\t\t\tremoteInfo = ShareExtension;\n'
    f'\t\t}};\n'
    f'\t\t{test_proxy_id} /* PBXContainerItemProxy */ = {{\n'
    f'\t\t\tisa = PBXContainerItemProxy;\n'
    f'\t\t\tcontainerPortal = {project_id} /* Project object */;\n'
    f'\t\t\tproxyType = 1;\n'
    f'\t\t\tremoteGlobalIDString = {target_id};\n'
    f'\t\t\tremoteInfo = TriliumMobile;\n'
    f'\t\t}};\n'
    '/* End PBXContainerItemProxy section */\n\n'
    '/* Begin PBXCopyFilesBuildPhase section */\n'
    f'{embed_txt}'
    '/* End PBXCopyFilesBuildPhase section */\n\n'
    '/* Begin PBXFileReference section */\n'
    f'{file_refs_txt}'
    '/* End PBXFileReference section */\n\n'
    '/* Begin PBXFrameworksBuildPhase section */\n'
    f'{frameworks_txt}'
    f'{test_frameworks_txt}'
    '/* End PBXFrameworksBuildPhase section */\n\n'
    '/* Begin PBXGroup section */\n'
    f'{groups_txt}'
    '/* End PBXGroup section */\n\n'
    '/* Begin PBXNativeTarget section */\n'
    f'{target_txt}'
    f'{ext_target_txt}'
    f'{test_target_txt}'
    '/* End PBXNativeTarget section */\n\n'
    '/* Begin PBXProject section */\n'
    f'{project_txt}'
    '/* End PBXProject section */\n\n'
    '/* Begin PBXResourcesBuildPhase section */\n'
    f'{resources_txt}'
    f'{ext_resources_txt}'
    '/* End PBXResourcesBuildPhase section */\n\n'
    '/* Begin PBXSourcesBuildPhase section */\n'
    f'{sources_txt}'
    f'{ext_sources_txt}'
    f'{test_sources_txt}'
    '/* End PBXSourcesBuildPhase section */\n\n'
    '/* Begin PBXTargetDependency section */\n'
    f'\t\t{ext_dep_id} /* PBXTargetDependency */ = {{\n'
    f'\t\t\tisa = PBXTargetDependency;\n'
    f'\t\t\ttarget = {ext_target_id} /* ShareExtension */;\n'
    f'\t\t\ttargetProxy = {ext_proxy_id} /* PBXContainerItemProxy */;\n'
    f'\t\t}};\n'
    f'\t\t{test_dep_id} /* PBXTargetDependency */ = {{\n'
    f'\t\t\tisa = PBXTargetDependency;\n'
    f'\t\t\ttarget = {target_id} /* TriliumMobile */;\n'
    f'\t\t\ttargetProxy = {test_proxy_id} /* PBXContainerItemProxy */;\n'
    f'\t\t}};\n'
    '/* End PBXTargetDependency section */\n\n'
    '/* Begin XCBuildConfiguration section */\n'
    f'{configs_txt}'
    '/* End XCBuildConfiguration section */\n\n'
    '/* Begin XCConfigurationList section */\n'
    f'{lists_txt}'
    '/* End XCConfigurationList section */\n'
    '\t};\n'
    f'\trootObject = {project_id} /* Project object */;\n'
    '}\n'
)

here = os.path.dirname(os.path.abspath(__file__))
xcodeproj = os.path.join(here, "TriliumMobile.xcodeproj")
os.makedirs(xcodeproj, exist_ok=True)
out = os.path.join(xcodeproj, "project.pbxproj")
with open(out, "w", encoding="utf-8") as fh:
    fh.write(pbxproj)

print(f"Wrote {out} ({len(pbxproj)} bytes), {len(SWIFT_FILES)} swift files.")
