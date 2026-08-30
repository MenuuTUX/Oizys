#!/usr/bin/env python3
"""Generate MView.xcodeproj.

The project is generated rather than committed by hand, so adding a source file never
means hand-editing a pbxproj. Object identifiers are derived from a hash of what they
name, which makes regeneration byte-identical and keeps the file out of diffs unless
something real changed.

Build settings are not in here. They live in Configs/*.xcconfig, referenced by each
configuration, so a setting can be reviewed in a diff and the IDE and command-line builds
cannot drift.

Targets
    MViewCore        static library, everything except the CLI entry point
    MViewCoreDylib   the same sources as a dylib, so the Python suite can drive them
                     through ctypes
    mview            the command-line tool
"""
import hashlib
import pathlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT = ROOT / "MView.xcodeproj"

FRAMEWORKS = [
    "Foundation", "CoreFoundation", "CoreGraphics", "CoreMedia", "CoreVideo", "IOKit",
    "IOUSBHost", "Security", "ScreenCaptureKit", "ImageIO", "UniformTypeIdentifiers",
]
CONFIGS = ["Debug", "Release", "Profile"]
XCCONFIG = {
    "Debug": "Configs/Debug.xcconfig",
    "Release": "Configs/Release.xcconfig",
    "Profile": "Configs/Profile.xcconfig",
}
LIBRARY_XCCONFIG = "Configs/Library.xcconfig"

# .mm is Objective-C++: C++ everywhere except the message sends Apple's frameworks force.
SOURCE_SUFFIXES = (".c", ".m", ".mm")


def oid(*parts):
    return hashlib.sha256("::".join(parts).encode()).hexdigest()[:24].upper()


def core_sources():
    directory = ROOT / "Sources" / "MViewCore"
    return sorted((p for p in directory.iterdir() if p.suffix in SOURCE_SUFFIXES),
                  key=lambda p: p.name)


def tool_sources():
    directory = ROOT / "Sources" / "mview"
    return sorted((p for p in directory.iterdir() if p.suffix in SOURCE_SUFFIXES),
                  key=lambda p: p.name)


def headers():
    directory = ROOT / "Sources" / "MViewCore" / "include"
    cli = ROOT / "Sources" / "mview"
    return sorted([*directory.glob("*.h"), *cli.glob("*.h")], key=lambda p: p.name)


class Project:
    def __init__(self):
        self.lines = []

    def add(self, text=""):
        self.lines.append(text)

    def render(self):
        return "\n".join(self.lines) + "\n"


def file_type(path):
    return {
        ".c": "sourcecode.c.c",
        ".m": "sourcecode.c.objc",
        ".mm": "sourcecode.cpp.objcpp",
        ".h": "sourcecode.c.h",
        ".xcconfig": "text.xcconfig",
    }[path.suffix]


def build():
    core = core_sources()
    tool = tool_sources()
    heads = headers()
    configs = [ROOT / path for path in XCCONFIG.values()] + [ROOT / LIBRARY_XCCONFIG]
    configs.append(ROOT / "Configs" / "Base.xcconfig")

    # Two targets, not three. A static libMViewCore.a and a dynamic libMViewCore.dylib
    # both land in the products directory, and the linker prefers the dylib -- so the tool
    # silently linked against it and then failed at launch with no LC_RPATH to find it.
    # The tool compiles the core sources directly; the dylib exists only for the tests.
    targets = {
        "MViewCoreDylib": ("com.apple.product-type.library.dynamic", "libMViewCore.dylib", core,
                           LIBRARY_XCCONFIG),
        "mview": ("com.apple.product-type.tool", "mview", tool + core, None),
    }

    p = Project()
    p.add("// !$*UTF8*$!")
    p.add("{")
    p.add("\tarchiveVersion = 1;")
    p.add("\tclasses = {")
    p.add("\t};")
    p.add("\tobjectVersion = 56;")
    p.add("\tobjects = {")
    p.add("")

    # --- PBXBuildFile: one per (file, target) pair -------------------------------
    p.add("/* Begin PBXBuildFile section */")
    for target, (_, _, sources, _) in targets.items():
        for path in sources:
            p.add(f"\t\t{oid('bf', target, path.name)} /* {path.name} in {target} */ = "
                  f"{{isa = PBXBuildFile; fileRef = {oid('fr', path.name)} /* {path.name} */; }};")
        for framework in FRAMEWORKS:
            p.add(f"\t\t{oid('bf', target, framework)} /* {framework} in {target} */ = "
                  f"{{isa = PBXBuildFile; fileRef = {oid('fr', framework)} "
                  f"/* {framework}.framework */; }};")
    p.add("/* End PBXBuildFile section */")
    p.add("")

    # --- PBXFileReference --------------------------------------------------------
    p.add("/* Begin PBXFileReference section */")
    for target, (_, product, _, _) in targets.items():
        kind = ("archive.ar" if product.endswith(".a") else
                "compiled.mach-o.dylib" if product.endswith(".dylib") else
                '"compiled.mach-o.executable"')
        p.add(f"\t\t{oid('product', target)} /* {product} */ = {{isa = PBXFileReference; "
              f"explicitFileType = {kind}; includeInIndex = 0; path = {product}; "
              f"sourceTree = BUILT_PRODUCTS_DIR; }};")
    for path in core + tool + heads:
        relative = path.relative_to(ROOT)
        p.add(f"\t\t{oid('fr', path.name)} /* {path.name} */ = {{isa = PBXFileReference; "
              f"lastKnownFileType = {file_type(path)}; name = {path.name}; "
              f"path = {relative}; sourceTree = SOURCE_ROOT; }};")
    for path in configs:
        p.add(f"\t\t{oid('fr', path.name)} /* {path.name} */ = {{isa = PBXFileReference; "
              f"lastKnownFileType = text.xcconfig; name = {path.name}; "
              f"path = Configs/{path.name}; sourceTree = SOURCE_ROOT; }};")
    for framework in FRAMEWORKS:
        p.add(f"\t\t{oid('fr', framework)} /* {framework}.framework */ = "
              f"{{isa = PBXFileReference; lastKnownFileType = wrapper.framework; "
              f"name = {framework}.framework; "
              f"path = System/Library/Frameworks/{framework}.framework; sourceTree = SDKROOT; }};")
    p.add("/* End PBXFileReference section */")
    p.add("")

    # --- PBXFrameworksBuildPhase --------------------------------------------------
    p.add("/* Begin PBXFrameworksBuildPhase section */")
    for target in targets:
        p.add(f"\t\t{oid('frameworksphase', target)} = {{")
        p.add("\t\t\tisa = PBXFrameworksBuildPhase;")
        p.add("\t\t\tbuildActionMask = 2147483647;")
        p.add("\t\t\tfiles = (")
        for framework in FRAMEWORKS:
            p.add(f"\t\t\t\t{oid('bf', target, framework)} /* {framework} */,")
        p.add("\t\t\t);")
        p.add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        p.add("\t\t};")
    p.add("/* End PBXFrameworksBuildPhase section */")
    p.add("")

    # --- PBXGroup -----------------------------------------------------------------
    def group(identifier, name, children, path=None):
        p.add(f"\t\t{identifier} /* {name} */ = {{")
        p.add("\t\t\tisa = PBXGroup;")
        p.add("\t\t\tchildren = (")
        for child_id, label in children:
            p.add(f"\t\t\t\t{child_id} /* {label} */,")
        p.add("\t\t\t);")
        p.add(f"\t\t\tname = {name};")
        if path:
            p.add(f"\t\t\tpath = {path};")
        p.add("\t\t\tsourceTree = \"<group>\";")
        p.add("\t\t};")

    p.add("/* Begin PBXGroup section */")
    group(oid("g", "root"), "MView", [
        (oid("g", "Sources"), "Sources"),
        (oid("g", "Configs"), "Configs"),
        (oid("g", "Frameworks"), "Frameworks"),
        (oid("g", "Products"), "Products"),
    ])
    group(oid("g", "Sources"), "Sources", [
        (oid("g", "MViewCore"), "MViewCore"),
        (oid("g", "tool"), "mview"),
    ])
    group(oid("g", "MViewCore"), "MViewCore",
          [(oid("g", "include"), "include")] + [(oid("fr", f.name), f.name) for f in core])
    group(oid("g", "include"), "include", [(oid("fr", f.name), f.name) for f in heads])
    group(oid("g", "tool"), "mview", [(oid("fr", f.name), f.name) for f in tool])
    group(oid("g", "Configs"), "Configs", [(oid("fr", f.name), f.name) for f in configs])
    group(oid("g", "Frameworks"), "Frameworks",
          [(oid("fr", f), f + ".framework") for f in FRAMEWORKS])
    group(oid("g", "Products"), "Products",
          [(oid("product", t), targets[t][1]) for t in targets])
    p.add("/* End PBXGroup section */")
    p.add("")

    # --- PBXNativeTarget ----------------------------------------------------------
    p.add("/* Begin PBXNativeTarget section */")
    for target, (product_type, product, _, _) in targets.items():
        p.add(f"\t\t{oid('target', target)} /* {target} */ = {{")
        p.add("\t\t\tisa = PBXNativeTarget;")
        p.add(f"\t\t\tbuildConfigurationList = {oid('configlist', target)};")
        p.add("\t\t\tbuildPhases = (")
        p.add(f"\t\t\t\t{oid('sourcesphase', target)},")
        p.add(f"\t\t\t\t{oid('frameworksphase', target)},")
        p.add("\t\t\t);")
        p.add("\t\t\tbuildRules = (")
        p.add("\t\t\t);")
        p.add("\t\t\tdependencies = (")
        p.add("\t\t\t);")
        p.add(f"\t\t\tname = {target};")
        p.add(f"\t\t\tproductName = {target};")
        p.add(f"\t\t\tproductReference = {oid('product', target)} /* {product} */;")
        p.add(f"\t\t\tproductType = \"{product_type}\";")
        p.add("\t\t};")
    p.add("/* End PBXNativeTarget section */")
    p.add("")

    # --- dependency ---------------------------------------------------------------
    # --- PBXProject ---------------------------------------------------------------
    p.add("/* Begin PBXProject section */")
    p.add(f"\t\t{oid('project')} /* Project object */ = {{")
    p.add("\t\t\tisa = PBXProject;")
    p.add("\t\t\tattributes = {")
    p.add("\t\t\t\tLastUpgradeCheck = 2600;")
    p.add("\t\t\t};")
    p.add(f"\t\t\tbuildConfigurationList = {oid('configlist', 'project')};")
    p.add("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
    p.add("\t\t\tdevelopmentRegion = en;")
    p.add("\t\t\thasScannedForEncodings = 0;")
    p.add("\t\t\tknownRegions = (")
    p.add("\t\t\t\ten,")
    p.add("\t\t\t);")
    p.add(f"\t\t\tmainGroup = {oid('g', 'root')};")
    p.add(f"\t\t\tproductRefGroup = {oid('g', 'Products')} /* Products */;")
    p.add("\t\t\tprojectDirPath = \"\";")
    p.add("\t\t\tprojectRoot = \"\";")
    p.add("\t\t\ttargets = (")
    for target in targets:
        p.add(f"\t\t\t\t{oid('target', target)} /* {target} */,")
    p.add("\t\t\t);")
    p.add("\t\t};")
    p.add("/* End PBXProject section */")
    p.add("")

    # --- PBXSourcesBuildPhase -----------------------------------------------------
    p.add("/* Begin PBXSourcesBuildPhase section */")
    for target, (_, _, sources, _) in targets.items():
        p.add(f"\t\t{oid('sourcesphase', target)} = {{")
        p.add("\t\t\tisa = PBXSourcesBuildPhase;")
        p.add("\t\t\tbuildActionMask = 2147483647;")
        p.add("\t\t\tfiles = (")
        for path in sources:
            p.add(f"\t\t\t\t{oid('bf', target, path.name)} /* {path.name} */,")
        p.add("\t\t\t);")
        p.add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
        p.add("\t\t};")
    p.add("/* End PBXSourcesBuildPhase section */")
    p.add("")

    # --- XCBuildConfiguration -----------------------------------------------------
    p.add("/* Begin XCBuildConfiguration section */")

    def configuration(scope, name, base_config, extra=()):
        p.add(f"\t\t{oid('config', scope, name)} /* {name} */ = {{")
        p.add("\t\t\tisa = XCBuildConfiguration;")
        p.add(f"\t\t\tbaseConfigurationReference = {oid('fr', pathlib.Path(base_config).name)} "
              f"/* {pathlib.Path(base_config).name} */;")
        p.add("\t\t\tbuildSettings = {")
        for key, value in extra:
            p.add(f"\t\t\t\t{key} = {value};")
        p.add("\t\t\t};")
        p.add(f"\t\t\tname = {name};")
        p.add("\t\t};")

    for name in CONFIGS:
        configuration("project", name, XCCONFIG[name])
    for target, (_, _, _, override) in targets.items():
        for name in CONFIGS:
            base = override or XCCONFIG[name]
            extra = [("PRODUCT_NAME", "MViewCore")] if target == "MViewCoreDylib" else []
            configuration(target, name, base, extra)
    p.add("/* End XCBuildConfiguration section */")
    p.add("")

    p.add("/* Begin XCConfigurationList section */")
    for scope in ["project"] + list(targets):
        p.add(f"\t\t{oid('configlist', scope)} = {{")
        p.add("\t\t\tisa = XCConfigurationList;")
        p.add("\t\t\tbuildConfigurations = (")
        for name in CONFIGS:
            p.add(f"\t\t\t\t{oid('config', scope, name)} /* {name} */,")
        p.add("\t\t\t);")
        p.add("\t\t\tdefaultConfigurationIsVisible = 0;")
        p.add("\t\t\tdefaultConfigurationName = Release;")
        p.add("\t\t};")
    p.add("/* End XCConfigurationList section */")
    p.add("")

    p.add("\t};")
    p.add(f"\trootObject = {oid('project')} /* Project object */;")
    p.add("}")
    return p.render()


SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES"
                           buildForProfiling = "YES" buildForArchiving = "YES"
                           buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary"
               BlueprintIdentifier = "{target_id}" BuildableName = "{product}"
               BlueprintName = "{target}" ReferencedContainer = "container:MView.xcodeproj" />
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
               selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
               shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "{launch_config}"
                 selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
                 selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
                 launchStyle = "0" useCustomWorkingDirectory = "YES"
                 customWorkingDirectory = "$(SRCROOT)"
                 debugDocumentVersioning = "YES" debugServiceExtension = "internal"
                 allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}" BuildableName = "{product}"
            BlueprintName = "{target}" ReferencedContainer = "container:MView.xcodeproj" />
      </BuildableProductRunnable>
      <CommandLineArguments>
{arguments}
      </CommandLineArguments>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Profile" shouldUseLaunchSchemeArgsEnv = "YES"
                  savedToolIdentifier = "" useCustomWorkingDirectory = "YES"
                  customWorkingDirectory = "$(SRCROOT)" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}" BuildableName = "{product}"
            BlueprintName = "{target}" ReferencedContainer = "container:MView.xcodeproj" />
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug" />
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES" />
</Scheme>
"""


def argument(value, enabled="YES"):
    return (f'         <CommandLineArgument argument = "{value}" '
            f'isEnabled = "{enabled}" />')


def main():
    if PROJECT.exists():
        shutil.rmtree(PROJECT)
    PROJECT.mkdir(parents=True)
    (PROJECT / "project.pbxproj").write_text(build())

    scheme_dir = PROJECT / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True)

    schemes = {
        # Run drives the live driver; Profile builds the frame-pointer configuration so
        # Instruments can walk the encoder's stack.
        "mview": ("mview", "Release", [argument("run", "NO"), argument("--takeover", "NO"),
                                       argument("bench", "YES")]),
        "mview-profile": ("mview", "Profile", [argument("profile")]),
        "MViewCoreDylib": ("libMViewCore.dylib", "Debug", []),
    }
    for name, (product, launch_config, arguments) in schemes.items():
        target = "mview" if product == "mview" else "MViewCoreDylib"
        (scheme_dir / f"{name}.xcscheme").write_text(SCHEME.format(
            target_id=oid("target", target), target=target, product=product,
            launch_config=launch_config, arguments="\n".join(arguments)))

    print(f"wrote {PROJECT.relative_to(ROOT)}: "
          f"{len(core)} core sources, {len(tool_sources())} tool sources, "
          f"{len(schemes)} schemes" if (core := core_sources()) else "")


if __name__ == "__main__":
    main()
