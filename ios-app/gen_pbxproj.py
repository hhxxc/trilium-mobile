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

file_ref_ids = {}
build_file_ids = {}
for f in SWIFT_FILES:
    file_ref_ids[f] = oid("FileRef." + f)
    build_file_ids[f] = oid("BuildFile." + f)

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
file_refs_txt = "".join(file_refs)

# ---- PBXGroup ----
group_children = ",\n".join(
    f"\t\t\t\t{file_ref_ids[f]} /* {os.path.basename(f)} */" for f in SWIFT_FILES
)
group_children += f",\n\t\t\t\t{assets_ref_id} /* {ASSET_CATALOG} */"
app_group = (
    f'\t\t{app_group_id} /* TriliumMobile */ = {{\n'
    f'\t\t\tisa = PBXGroup;\n'
    f'\t\t\tchildren = (\n{group_children},\n'
    f'\t\t\t);\n'
    f'\t\t\tpath = TriliumMobile;\n'
    f'\t\t\tsourceTree = "<group>";\n'
    f'\t\t}};\n'
)
main_group = (
    f'\t\t{main_group_id} = {{\n'
    f'\t\t\tisa = PBXGroup;\n'
    f'\t\t\tchildren = (\n'
    f'\t\t\t\t{app_group_id} /* TriliumMobile */,\n'
    f'\t\t\t\t{product_id} /* TriliumMobile.app */,\n'
    f'\t\t\t);\n'
    f'\t\t\tsourceTree = "<group>";\n'
    f'\t\t}};\n'
)
groups_txt = app_group + main_group

# ---- PBXNativeTarget ----
target_txt = (
    f'\t\t{target_id} /* TriliumMobile */ = {{\n'
    f'\t\t\tisa = PBXNativeTarget;\n'
    f'\t\t\tbuildConfigurationList = {target_cl_id} /* Build configuration list for PBXNativeTarget "TriliumMobile" */;\n'
    f'\t\t\tbuildPhases = (\n'
    f'\t\t\t\t{sources_id} /* Sources */,\n'
    f'\t\t\t\t{frameworks_id} /* Frameworks */,\n'
    f'\t\t\t\t{resources_id} /* Resources */,\n'
    f'\t\t\t);\n'
    f'\t\t\tbuildRules = (\n'
    f'\t\t\t);\n'
    f'\t\t\tdependencies = (\n'
    f'\t\t\t);\n'
    f'\t\t\tname = TriliumMobile;\n'
    f'\t\t\tproductName = TriliumMobile;\n'
    f'\t\t\tproductReference = {product_id} /* TriliumMobile.app */;\n'
    f'\t\t\tproductType = "com.apple.product-type.application";\n'
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
resources_txt = (
    f'\t\t{resources_id} /* Resources */ = {{\n'
    f'\t\t\tisa = PBXResourcesBuildPhase;\n'
    f'\t\t\tbuildActionMask = 2147483647;\n'
    f'\t\t\tfiles = (\n'
    f'\t\t\t\t{assets_build_id} /* {ASSET_CATALOG} in Resources */,\n'
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
    '/* Begin PBXFileReference section */\n'
    f'{file_refs_txt}'
    '/* End PBXFileReference section */\n\n'
    '/* Begin PBXFrameworksBuildPhase section */\n'
    f'{frameworks_txt}'
    '/* End PBXFrameworksBuildPhase section */\n\n'
    '/* Begin PBXGroup section */\n'
    f'{groups_txt}'
    '/* End PBXGroup section */\n\n'
    '/* Begin PBXNativeTarget section */\n'
    f'{target_txt}'
    '/* End PBXNativeTarget section */\n\n'
    '/* Begin PBXProject section */\n'
    f'{project_txt}'
    '/* End PBXProject section */\n\n'
    '/* Begin PBXResourcesBuildPhase section */\n'
    f'{resources_txt}'
    '/* End PBXResourcesBuildPhase section */\n\n'
    '/* Begin PBXSourcesBuildPhase section */\n'
    f'{sources_txt}'
    '/* End PBXSourcesBuildPhase section */\n\n'
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
