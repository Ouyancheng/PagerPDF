#!/usr/bin/env python3
import os
from pathlib import Path

ROOT = Path("/Volumes/Data/workspace/PagerPDF")
os.chdir(ROOT)

def collect(folder, suffixes):
    files = []
    for path in sorted((ROOT / folder).rglob("*")):
        if path.is_file() and path.suffix in suffixes and path.name != "Info.plist":
            files.append(path.relative_to(ROOT).as_posix())
    return files

core_sources = collect("Core", {".cpp", ".mm"})
mac_sources = collect("Platform/Mac", {".mm"})
pad_sources = collect("Platform/Pad", {".mm"})
test_sources = collect("Tests", {".mm"})

counter = 0x1000

def uid():
    global counter
    counter += 1
    return f"A1{counter:022X}"

ids = {}

def ident(key):
    if key not in ids:
        ids[key] = uid()
    return ids[key]

objects = []

def add(oid, isa, **fields):
    objects.append((oid, isa, fields))

def file_ref(path, kind):
    key = f"ref:{path}"
    if key in ids:
        return ids[key]
    oid = ident(key)
    name = Path(path).name
    add(oid, "PBXFileReference", lastKnownFileType=kind, path=name, sourceTree="<group>")
    return oid

def source_file(path):
    kind = "sourcecode.cpp.objcpp" if path.endswith(".mm") else "sourcecode.cpp.cpp"
    return file_ref(path, kind)

groups = {}

def ensure_group(path):
    if path in groups:
        return groups[path]
    oid = ident(f"group:{path or '.'}")
    groups[path] = oid
    return oid

# Pre-create group nodes bottom-up after we know children.
group_children = {}

def add_child(group_path, child_id, child_name, is_group=False):
    group_children.setdefault(group_path, []).append((child_name, child_id, is_group))

for path in core_sources + mac_sources + pad_sources + test_sources:
    source_file(path)
    parent = str(Path(path).parent)
    add_child(parent, ident(f"ref:{path}"), Path(path).name)

plist_mac = file_ref("Platform/Mac/Info.plist", "text.plist.xml")
add_child("Platform/Mac", plist_mac, "Info.plist")
plist_pad = file_ref("Platform/Pad/Info.plist", "text.plist.xml")
add_child("Platform/Pad", plist_pad, "Info.plist")
assets_mac = file_ref("Platform/Mac/Assets.xcassets", "folder.assetcatalog")
add_child("Platform/Mac", assets_mac, "Assets.xcassets")
assets_pad = file_ref("Platform/Pad/Assets.xcassets", "folder.assetcatalog")
add_child("Platform/Pad", assets_pad, "Assets.xcassets")

# Intermediate directories
all_dirs = set()
for path in list(group_children):
    current = path
    while current:
        all_dirs.add(current)
        parent = str(Path(current).parent)
        if parent == current or parent == ".":
            break
        current = parent

for directory in sorted(all_dirs, key=lambda item: item.count("/"), reverse=True):
    parent = str(Path(directory).parent)
    if parent == directory:
        parent = ""
    add_child(parent if parent != "." else "", ident(f"group:{directory}"), Path(directory).name, True)

product_core = ident("product:core")
product_mac = ident("product:mac")
product_pad = ident("product:pad")
product_tests = ident("product:tests")
add(product_core, "PBXFileReference", explicitFileType="archive.ar", includeInIndex=0, path="libPagerCore.a", sourceTree="BUILT_PRODUCTS_DIR")
add(product_mac, "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path="PagerMac.app", sourceTree="BUILT_PRODUCTS_DIR")
add(product_pad, "PBXFileReference", explicitFileType="wrapper.application", includeInIndex=0, path="PagerPad.app", sourceTree="BUILT_PRODUCTS_DIR")
add(product_tests, "PBXFileReference", explicitFileType="wrapper.cfbundle", includeInIndex=0, path="PagerCoreTests.xctest", sourceTree="BUILT_PRODUCTS_DIR")

products_group = ident("group:Products")
main_group = ident("group:Main")

def emit_groups():
    for path, children in group_children.items():
        if path == "":
            continue
        oid = ident(f"group:{path}")
        child_ids = [child_id for _, child_id, _ in sorted(children, key=lambda item: item[0].lower())]
        add(oid, "PBXGroup", children=child_ids, path=Path(path).name, sourceTree="<group>")

emit_groups()
root_children = [child_id for _, child_id, _ in sorted(group_children.get("", []), key=lambda item: item[0].lower())]
root_children.append(products_group)
add(products_group, "PBXGroup", children=[product_core, product_mac, product_pad, product_tests], name="Products", sourceTree="<group>")
add(main_group, "PBXGroup", children=root_children, sourceTree="<group>")

def build_file(path):
    oid = ident(f"build:{path}")
    add(oid, "PBXBuildFile", fileRef=ident(f"ref:{path}"))
    return oid

def product_build(product_id, name):
    oid = ident(f"buildprod:{name}")
    add(oid, "PBXBuildFile", fileRef=product_id)
    return oid

core_build = [build_file(path) for path in core_sources]
mac_build = [build_file(path) for path in mac_sources]
pad_build = [build_file(path) for path in pad_sources]
test_build = [build_file(path) for path in test_sources]
mac_link = [product_build(product_core, "mac")]
pad_link = [product_build(product_core, "pad")]
test_link = []

core_sources_phase = ident("phase:core:sources")
mac_sources_phase = ident("phase:mac:sources")
pad_sources_phase = ident("phase:pad:sources")
test_sources_phase = ident("phase:test:sources")
mac_frameworks = ident("phase:mac:frameworks")
pad_frameworks = ident("phase:pad:frameworks")
test_frameworks = ident("phase:test:frameworks")
core_frameworks = ident("phase:core:frameworks")
add(core_sources_phase, "PBXSourcesBuildPhase", buildActionMask=2147483647, files=core_build, runOnlyForDeploymentPostprocessing=0)
add(mac_sources_phase, "PBXSourcesBuildPhase", buildActionMask=2147483647, files=mac_build, runOnlyForDeploymentPostprocessing=0)
add(pad_sources_phase, "PBXSourcesBuildPhase", buildActionMask=2147483647, files=pad_build, runOnlyForDeploymentPostprocessing=0)
add(test_sources_phase, "PBXSourcesBuildPhase", buildActionMask=2147483647, files=test_build, runOnlyForDeploymentPostprocessing=0)
add(core_frameworks, "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=[], runOnlyForDeploymentPostprocessing=0)
add(mac_frameworks, "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=mac_link, runOnlyForDeploymentPostprocessing=0)
add(pad_frameworks, "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=pad_link, runOnlyForDeploymentPostprocessing=0)
add(test_frameworks, "PBXFrameworksBuildPhase", buildActionMask=2147483647, files=test_link, runOnlyForDeploymentPostprocessing=0)

mac_resources_phase = ident("phase:mac:resources")
pad_resources_phase = ident("phase:pad:resources")
mac_resources = [ident("build:Platform/Mac/Assets.xcassets")]
pad_resources = [ident("build:Platform/Pad/Assets.xcassets")]
add(ident("build:Platform/Mac/Assets.xcassets"), "PBXBuildFile", fileRef=assets_mac)
add(ident("build:Platform/Pad/Assets.xcassets"), "PBXBuildFile", fileRef=assets_pad)
add(mac_resources_phase, "PBXResourcesBuildPhase", buildActionMask=2147483647, files=mac_resources, runOnlyForDeploymentPostprocessing=0)
add(pad_resources_phase, "PBXResourcesBuildPhase", buildActionMask=2147483647, files=pad_resources, runOnlyForDeploymentPostprocessing=0)

project_id = ident("project")
core_target = ident("target:core")
mac_target = ident("target:mac")
pad_target = ident("target:pad")
test_target = ident("target:test")

def dependency(name, target):
    proxy = ident(f"proxy:{name}")
    dep = ident(f"dep:{name}")
    add(proxy, "PBXContainerItemProxy", containerPortal=project_id, proxyType=1, remoteGlobalIDString=target, remoteInfo=name)
    add(dep, "PBXTargetDependency", target=target, targetProxy=proxy)
    return dep

mac_dep = dependency("PagerCore", core_target)
pad_dep = dependency("PagerCorePad", core_target)
test_dep_core = dependency("PagerCoreTest", core_target)
test_dep_mac = dependency("PagerMac", mac_target)

add(core_target, "PBXNativeTarget",
    buildConfigurationList=ident("cfglist:core"),
    buildPhases=[core_sources_phase, core_frameworks],
    buildRules=[],
    dependencies=[],
    name="PagerCore",
    productName="PagerCore",
    productReference=product_core,
    productType="com.apple.product-type.library.static")
add(mac_target, "PBXNativeTarget",
    buildConfigurationList=ident("cfglist:mac"),
    buildPhases=[mac_sources_phase, mac_frameworks, mac_resources_phase],
    buildRules=[],
    dependencies=[mac_dep],
    name="PagerMac",
    productName="PagerMac",
    productReference=product_mac,
    productType="com.apple.product-type.application")
add(pad_target, "PBXNativeTarget",
    buildConfigurationList=ident("cfglist:pad"),
    buildPhases=[pad_sources_phase, pad_frameworks, pad_resources_phase],
    buildRules=[],
    dependencies=[pad_dep],
    name="PagerPad",
    productName="PagerPad",
    productReference=product_pad,
    productType="com.apple.product-type.application")
add(test_target, "PBXNativeTarget",
    buildConfigurationList=ident("cfglist:test"),
    buildPhases=[test_sources_phase, test_frameworks],
    buildRules=[],
    dependencies=[test_dep_core, test_dep_mac],
    name="PagerCoreTests",
    productName="PagerCoreTests",
    productReference=product_tests,
    productType="com.apple.product-type.bundle.unit-test")

common = {
    "CLANG_CXX_LANGUAGE_STANDARD": "c++20",
    "CLANG_CXX_LIBRARY": "libc++",
    "GCC_ENABLE_CPP_EXCEPTIONS": "NO",
    "GCC_ENABLE_CPP_RTTI": "NO",
    "CLANG_ENABLE_OBJC_ARC": "YES",
    "CLANG_ENABLE_MODULES": "YES",
    "CODE_SIGNING_ALLOWED": "NO",
    "CODE_SIGN_IDENTITY": "",
    "ENABLE_HARDENED_RUNTIME": "NO",
    "HEADER_SEARCH_PATHS": "$(SRCROOT)/Core/Include $(SRCROOT)/Core/Bridge",
    "MACOSX_DEPLOYMENT_TARGET": "14.0",
    "IPHONEOS_DEPLOYMENT_TARGET": "17.0",
    "CLANG_WARN_QUOTED_INCLUDE_IN_FRAMEWORK_HEADER": "NO",
    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    "GCC_C_LANGUAGE_STANDARD": "gnu17",
}

def config(name, extra, debug):
    oid = ident(f"cfg:{name}:{debug}")
    settings = dict(common)
    settings.update(extra)
    settings["DEBUG_INFORMATION_FORMAT"] = "dwarf" if debug else "dwarf-with-dsym"
    settings["GCC_OPTIMIZATION_LEVEL"] = "0" if debug else "s"
    settings["ONLY_ACTIVE_ARCH"] = "YES" if debug else "NO"
    settings["MTL_ENABLE_DEBUG_INFO"] = "INCLUDE_SOURCE" if debug else "NO"
    settings["ENABLE_NS_ASSERTIONS"] = "YES" if debug else "NO"
    settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = ""
    if debug:
        settings["GCC_PREPROCESSOR_DEFINITIONS"] = "DEBUG=1"
    add(oid, "XCBuildConfiguration", name="Debug" if debug else "Release", buildSettings=settings)
    return oid

def config_list(name, extra):
    oid = ident(f"cfglist:{name}")
    debug = config(name, extra, True)
    release = config(name, extra, False)
    add(oid, "XCConfigurationList", buildConfigurations=[debug, release], defaultConfigurationIsVisible=0, defaultConfigurationName="Debug")
    return oid

project_extra = {
    "SDKROOT": "auto",
    "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
}
core_extra = {
    "PRODUCT_NAME": "PagerCore",
    "EXECUTABLE_PREFIX": "lib",
    "SKIP_INSTALL": "YES",
    "SDKROOT": "auto",
    "SUPPORTED_PLATFORMS": "macosx iphoneos iphonesimulator",
    "MACH_O_TYPE": "staticlib",
    "OTHER_LDFLAGS": "-framework Foundation -framework CoreGraphics -framework CoreText -framework PDFKit",
}
mac_extra = {
    "PRODUCT_NAME": "PagerMac",
    "PRODUCT_BUNDLE_IDENTIFIER": "com.pagerpdf.mac",
    "INFOPLIST_FILE": "Platform/Mac/Info.plist",
    "SDKROOT": "macosx",
    "SUPPORTED_PLATFORMS": "macosx",
    "GENERATE_INFOPLIST_FILE": "NO",
    "LD_RUNPATH_SEARCH_PATHS": "@executable_path/../Frameworks",
    # -export_dynamic lets the app-hosted test bundle resolve app classes (bundle loader);
    # -all_load keeps core objects the app itself never references so tests can use them.
    "OTHER_LDFLAGS": "-framework AppKit -framework PDFKit -framework CoreText -framework CoreGraphics -framework Foundation -framework UniformTypeIdentifiers -framework QuartzCore -Wl,-export_dynamic -Wl,-all_load",
    # Scheme builds default this to YES, which would hide PagerDocument/PagerDocumentView
    # from the test bundle even with -export_dynamic; keep app symbols visible.
    "GCC_SYMBOLS_PRIVATE_EXTERN": "NO",
    "COMBINE_HIDPI_IMAGES": "YES",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
}
pad_extra = {
    "PRODUCT_NAME": "PagerPad",
    "PRODUCT_BUNDLE_IDENTIFIER": "com.pagerpdf.pad",
    "INFOPLIST_FILE": "Platform/Pad/Info.plist",
    "SDKROOT": "iphoneos",
    "SUPPORTED_PLATFORMS": "iphoneos iphonesimulator",
    "TARGETED_DEVICE_FAMILY": "2",
    "GENERATE_INFOPLIST_FILE": "NO",
    "LD_RUNPATH_SEARCH_PATHS": "@executable_path/Frameworks",
    "OTHER_LDFLAGS": "-framework UIKit -framework PDFKit -framework CoreText -framework CoreGraphics -framework Foundation -framework UniformTypeIdentifiers -framework QuartzCore",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
}
test_extra = {
    "PRODUCT_NAME": "PagerCoreTests",
    "PRODUCT_BUNDLE_IDENTIFIER": "com.pagerpdf.tests",
    "SDKROOT": "macosx",
    "SUPPORTED_PLATFORMS": "macosx",
    "GENERATE_INFOPLIST_FILE": "YES",
    "BUNDLE_LOADER": "$(TEST_HOST)",
    "TEST_HOST": "$(BUILT_PRODUCTS_DIR)/PagerMac.app/Contents/MacOS/PagerMac",
    "LD_RUNPATH_SEARCH_PATHS": "@loader_path/../Frameworks @executable_path/../Frameworks",
    # Platform/Mac is on the header search path so tests can exercise the Mac view classes;
    # their symbols resolve from the test host (BUNDLE_LOADER) at runtime.
    "HEADER_SEARCH_PATHS": "$(SRCROOT)/Core/Include $(SRCROOT)/Core/Bridge $(SRCROOT)/Platform/Mac",
    # -undefined dynamic_lookup: host app classes (PagerDocument, PagerDocumentView) resolve
    # from the test-host process at load time.
    "OTHER_LDFLAGS": "-framework XCTest -framework AppKit -framework PDFKit -framework CoreText -framework CoreGraphics -framework QuartzCore -framework Foundation -Wl,-undefined,dynamic_lookup",
    "SKIP_INSTALL": "YES",
}

config_list("project", project_extra)
config_list("core", core_extra)
config_list("mac", mac_extra)
config_list("pad", pad_extra)
config_list("test", test_extra)

add(project_id, "PBXProject",
    attributes={"BuildIndependentTargetsInParallel": 1, "LastUpgradeCheck": 1600},
    buildConfigurationList=ident("cfglist:project"),
    compatibilityVersion="Xcode 14.0",
    developmentRegion="en",
    hasScannedForEncodings=0,
    knownRegions=["en", "Base"],
    mainGroup=main_group,
    productRefGroup=products_group,
    projectDirPath="",
    projectRoot="",
    targets=[core_target, mac_target, pad_target, test_target])

def q(value):
    if isinstance(value, str):
        escaped = value.replace("\\", "\\\\").replace('"', '\\"')
        return '"' + escaped + '"'
    return str(value)

def emit_value(value, indent):
    if isinstance(value, list):
        if not value:
            return "(\n" + "\t" * indent + ")"
        lines = ["("]
        for item in value:
            lines.append("\t" * (indent + 1) + q(item) + ",")
        lines.append("\t" * indent + ")")
        return "\n".join(lines)
    if isinstance(value, dict):
        lines = ["{"]
        for key in value:
            lines.append("\t" * (indent + 1) + f"{q(key)} = {emit_value(value[key], indent + 1)};")
        lines.append("\t" * indent + "}")
        return "\n".join(lines)
    if isinstance(value, bool):
        return "1" if value else "0"
    if isinstance(value, int) and not isinstance(value, bool):
        return str(value)
    return q(value)

sections = {}
for oid, isa, fields in objects:
    sections.setdefault(isa, []).append((oid, fields))

order = [
    "PBXBuildFile",
    "PBXContainerItemProxy",
    "PBXFileReference",
    "PBXFrameworksBuildPhase",
    "PBXGroup",
    "PBXNativeTarget",
    "PBXProject",
    "PBXResourcesBuildPhase",
    "PBXSourcesBuildPhase",
    "PBXTargetDependency",
    "XCBuildConfiguration",
    "XCConfigurationList",
]
lines = [
    "// !$*UTF8*$!",
    "{",
    "\tarchiveVersion = 1;",
    "\tclasses = {",
    "\t};",
    "\tobjectVersion = 56;",
    "\tobjects = {",
    "",
]
for isa in order:
    lines.append(f"/* Begin {isa} section */")
    for oid, fields in sections.get(isa, []):
        lines.append(f"\t\t{oid} /* {isa} */ = {{")
        lines.append(f"\t\t\tisa = {isa};")
        for key, value in fields.items():
            lines.append(f"\t\t\t{key} = {emit_value(value, 3)};")
        lines.append("\t\t};")
    lines.append(f"/* End {isa} section */")
    lines.append("")
lines += ["\t};", f"\trootObject = {project_id} /* Project object */;", "}", ""]
(ROOT / "PagerPDF.xcodeproj").mkdir(exist_ok=True)
(ROOT / "PagerPDF.xcodeproj" / "project.pbxproj").write_text("\n".join(lines))
print(f"core {len(core_sources)} mac {len(mac_sources)} pad {len(pad_sources)} tests {len(test_sources)}")
print("CORE", core_target)
print("MAC", mac_target)
print("PAD", pad_target)
print("TEST", test_target)

scheme_dir = ROOT / "PagerPDF.xcodeproj" / "xcshareddata" / "xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)

def scheme(name, target, product, test_target=None, test_product=None):
    testables = ""
    if test_target:
        testables = f"""
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{test_target}"
               BuildableName = "{test_product}"
               BlueprintName = "PagerCoreTests"
               ReferencedContainer = "container:PagerPDF.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>"""
    text = f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target}"
               BuildableName = "{product}"
               BlueprintName = "{name}"
               ReferencedContainer = "container:PagerPDF.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">{testables}
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target}"
            BuildableName = "{product}"
            BlueprintName = "{name}"
            ReferencedContainer = "container:PagerPDF.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    (scheme_dir / f"{name}.xcscheme").write_text(text)

scheme("PagerMac", mac_target, "PagerMac.app")
scheme("PagerPad", pad_target, "PagerPad.app")
scheme("PagerCoreTests", mac_target, "PagerMac.app", test_target, "PagerCoreTests.xctest")

