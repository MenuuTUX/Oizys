#!/usr/bin/env python3
"""Generate Oizys.xcodeproj.

The project is generated rather than committed by hand, so adding a source file never
means hand-editing a pbxproj. Object identifiers are derived from a hash of what they
name, which makes regeneration byte-identical and keeps the file out of diffs unless
something real changed.

Build settings are not in here. They live in Configs/*.xcconfig, referenced by each
configuration, so a setting can be reviewed in a diff and the IDE and command-line builds
cannot drift.

Targets
    OizysCore        static library, everything except the CLI entry point
    OizysCoreDylib   the same sources as a dylib, so the Python suite can drive them
                     through ctypes
    oizys            the command-line tool
"""
import hashlib
import pathlib
import json

ROOT = pathlib.Path(__file__).resolve().parent.parent
PROJECT = ROOT / "Oizys.xcodeproj"

FRAMEWORKS = [
    "AppKit", "Foundation", "CoreFoundation", "CoreGraphics", "CoreMedia", "CoreVideo", "IOKit",
    "IOUSBHost", "Security", "ScreenCaptureKit", "ImageIO", "UniformTypeIdentifiers",
]
CONFIGS = ["Debug", "Release", "Profile", "DebugMinimal", "DebugVerbose", "DebugFallback", "Production", "ProductionFallback", "ProductionProfile", "ProductionFallbackProfile"]
XCCONFIG = {
    "Debug": "Configs/Debug.xcconfig",
    "Release": "Configs/Release.xcconfig",
    "Profile": "Configs/Profile.xcconfig",
}
XCCONFIG.update({name: f"Configs/{name}.xcconfig" for name in CONFIGS if name not in XCCONFIG})
LIBRARY_XCCONFIG = "Configs/Library.xcconfig"

# C/C++ driver and Swift framework integration. No Objective-C source files.
SOURCE_SUFFIXES = (".c", ".cpp", ".swift")


def oid(*parts):
    return hashlib.sha256("::".join(parts).encode()).hexdigest()[:24].upper()


def core_sources():
    directory = ROOT / "Sources" / "OizysCore"
    return sorted((p for p in [*directory.iterdir(), *(ROOT / "Sources/OizysPlatform").glob("*.swift"), *(ROOT / "Sources/Support").glob("*.swift")] if p.suffix in SOURCE_SUFFIXES),
                  key=lambda p: p.name)


def tool_sources():
    directory = ROOT / "Sources" / "oizys"
    return sorted((p for p in directory.iterdir() if p.suffix in SOURCE_SUFFIXES),
                  key=lambda p: p.name)


def headers():
    directory = ROOT / "Sources" / "OizysCore" / "include"
    cli = ROOT / "Sources" / "oizys"
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
        ".cpp": "sourcecode.cpp.cpp",
        ".swift": "sourcecode.swift",
        ".m": "sourcecode.c.objc",
        ".mm": "sourcecode.cpp.objcpp",
        ".h": "sourcecode.c.h",
        ".xcconfig": "text.xcconfig",
    }.get(path.suffix, "text")


def build():
    core = core_sources()
    tool = tool_sources()
    heads = headers()
    app = sorted((ROOT / "Sources/OizysApp").glob("*.swift"))
    shared = sorted((ROOT / "Sources/Support").glob("*.swift"))
    xctests = sorted((ROOT / "Tests/Xcode").glob("*.swift"))
    extras = sorted(p for directory in ("Tools", "Tests", "Documentation") for p in (ROOT / directory).rglob("*")
                    if p.is_file() and not p.is_symlink() and "__pycache__" not in p.parts
                    and p.suffix in (".py", ".swift", ".c", ".h", ".sh", ".md", ".m") and p not in xctests)
    extras += [ROOT / "dev.sh", ROOT / "README.md", ROOT / "VERSION", ROOT / "Sources/OizysApp/Info.plist"]
    configs = [ROOT / path for path in XCCONFIG.values()] + [ROOT / LIBRARY_XCCONFIG]
    configs.append(ROOT / "Configs" / "Base.xcconfig")
    extras.append(ROOT / "Configs/Debug.entitlements")

    # The CLI compiles core sources directly so it never accidentally links the test dylib.
    # The native app embeds that CLI; XCTest uses the separate dynamic library.
    targets = {
        "OizysCoreDylib": ("com.apple.product-type.library.dynamic", "libOizysCore.dylib", core,
                           LIBRARY_XCCONFIG),
        "oizys": ("com.apple.product-type.tool", "oizys", tool + core, None),
        "OizysApp": ("com.apple.product-type.application", "Oizys.app", app + shared, None),
        "OizysTests": ("com.apple.product-type.bundle.unit-test", "OizysTests.xctest", xctests, None),
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
        kind = ("wrapper.application" if product.endswith(".app") else
                "wrapper.cfbundle" if product.endswith(".xctest") else
                "archive.ar" if product.endswith(".a") else
                "compiled.mach-o.dylib" if product.endswith(".dylib") else
                '"compiled.mach-o.executable"')
        p.add(f"\t\t{oid('product', target)} /* {product} */ = {{isa = PBXFileReference; "
              f"explicitFileType = {kind}; includeInIndex = 0; path = {product}; "
              f"sourceTree = BUILT_PRODUCTS_DIR; }};")
    for path in core + tool + heads + app + xctests:
        relative = path.relative_to(ROOT)
        p.add(f"\t\t{oid('fr', path.name)} /* {path.name} */ = {{isa = PBXFileReference; "
              f"lastKnownFileType = {file_type(path)}; name = {path.name}; "
              f"path = {relative}; sourceTree = SOURCE_ROOT; }};")
    for path in extras:
        relative = path.relative_to(ROOT).as_posix()
        p.add(f'\t\t{oid("extra", relative)} = {{isa = PBXFileReference; lastKnownFileType = {file_type(path)}; '
              f'name = {json.dumps(path.name)}; path = {json.dumps(relative)}; sourceTree = SOURCE_ROOT; }};')
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
    group(oid("g", "root"), "Oizys", [
        (oid("g", "Sources"), "Sources"),
        (oid("g", "Configs"), "Configs"),
        (oid("g", "ToolsTestsDocs"), "ToolsTestsDocs"),
        (oid("g", "Frameworks"), "Frameworks"),
        (oid("g", "Products"), "Products"),
    ])
    group(oid("g", "Sources"), "Sources", [
        (oid("g", "OizysCore"), "OizysCore"),
        (oid("g", "tool"), "oizys"),
        (oid("g", "OizysApp"), "OizysApp"),
        (oid("g", "XcodeTests"), "XcodeTests"),
    ])
    group(oid("g", "OizysCore"), "OizysCore",
          [(oid("g", "include"), "include")] + [(oid("fr", f.name), f.name) for f in core])
    group(oid("g", "include"), "include", [(oid("fr", f.name), f.name) for f in heads])
    group(oid("g", "tool"), "oizys", [(oid("fr", f.name), f.name) for f in tool])
    group(oid("g", "OizysApp"), "OizysApp", [(oid("fr", f.name), f.name) for f in app])
    group(oid("g", "XcodeTests"), "XcodeTests", [(oid("fr", f.name), f.name) for f in xctests])
    group(oid("g", "ToolsTestsDocs"), "ToolsTestsDocs",
          [(oid("extra", f.relative_to(ROOT).as_posix()), f.name) for f in extras])
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
        if target == "OizysApp": p.add(f"\t\t\t\t{oid('resourcesphase', target)},")
        p.add("\t\t\t);")
        p.add("\t\t\tbuildRules = (")
        p.add("\t\t\t);")
        p.add("\t\t\tdependencies = (")
        if target in ("OizysApp", "OizysTests"):
            p.add(f"\t\t\t\t{oid('dependency', target)},")
        p.add("\t\t\t);")
        p.add(f"\t\t\tname = {target};")
        p.add(f"\t\t\tproductName = {target};")
        p.add(f"\t\t\tproductReference = {oid('product', target)} /* {product} */;")
        p.add(f"\t\t\tproductType = \"{product_type}\";")
        p.add("\t\t};")
    p.add("/* End PBXNativeTarget section */")
    p.add("")

    # --- Embedded app resources and explicit target dependencies ------------------
    script = '/usr/bin/python3 "$SRCROOT/Tools/package_resources.py" --xcode\n'
    p.add(f'\t\t{oid("resourcesphase", "OizysApp")} = {{isa = PBXShellScriptBuildPhase; '
          'buildActionMask = 2147483647; files = (); inputPaths = (); '
          'outputPaths = ("$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/build-info.json", '
          '"$(TARGET_BUILD_DIR)/$(EXECUTABLE_FOLDER_PATH)/OizysDriver"); '
          'alwaysOutOfDate = 1; runOnlyForDeploymentPostprocessing = 0; '
          f'name = "Bundle driver and developer resources"; shellPath = /bin/bash; shellScript = {json.dumps(script)}; }};')
    for dependent, dependency in (("OizysApp", "oizys"), ("OizysTests", "OizysCoreDylib")):
        p.add(f'\t\t{oid("proxy", dependent)} = {{isa = PBXContainerItemProxy; '
              f'containerPortal = {oid("project")}; proxyType = 1; remoteGlobalIDString = {oid("target", dependency)}; '
              f'remoteInfo = {dependency}; }};')
        p.add(f'\t\t{oid("dependency", dependent)} = {{isa = PBXTargetDependency; '
              f'target = {oid("target", dependency)}; targetProxy = {oid("proxy", dependent)}; }};')
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
            extra = [("PRODUCT_NAME", "OizysCore")] if target == "OizysCoreDylib" else []
            if target == "OizysApp":
                production = name.startswith("Production")
                variant = {"Production": "production", "ProductionFallback": "production-fallback",
                           "DebugVerbose": "debug-verbose", "DebugFallback": "debug-fallback"}.get(name.removesuffix("Profile") if name.startswith("Production") else name, "debug-minimal")
                product = "Oizys" if production else "Oizys-debug"
                version = (ROOT / "VERSION").read_text().strip()
                extra += [("PRODUCT_NAME", json.dumps(product)), ("PRODUCT_MODULE_NAME", "OizysApplication"), ("PRODUCT_BUNDLE_IDENTIFIER", json.dumps("org.oizys.Oizys." + ("production" if production else variant))),
                          ("GENERATE_INFOPLIST_FILE", "NO"), ("INFOPLIST_FILE", "Sources/OizysApp/Info.plist"), ("SWIFT_OBJC_BRIDGING_HEADER", '""'),
                          ("OIZYS_DISPLAY_NAME", json.dumps(product if production else product + " $(MARKETING_VERSION)")),
                          ("INFOPLIST_KEY_LSUIElement", "YES"), ("INFOPLIST_KEY_NSHighResolutionCapable", "YES"),
                          ("OIZYS_VARIANT", json.dumps(variant)),
                          ("OIZYS_FALLBACK", "YES" if "Fallback" in name else "NO"),
                          ("MARKETING_VERSION", json.dumps(version)), ("CURRENT_PROJECT_VERSION", json.dumps(version)),
                          ("CODE_SIGN_STYLE", "Manual"), ("CODE_SIGN_IDENTITY", '"-"'),
                          ("ENABLE_USER_SCRIPT_SANDBOXING", "NO"),
                          ("INSTALL_PATH", '"$(LOCAL_APPS_DIR)"'), ("SKIP_INSTALL", "NO")]
            elif target == "OizysTests":
                extra += [("GENERATE_INFOPLIST_FILE", "YES"), ("PRODUCT_BUNDLE_IDENTIFIER", "org.oizys.tests"),
                          ("SWIFT_OBJC_BRIDGING_HEADER", '""'), ("ENABLE_TESTING_SEARCH_PATHS", "YES"),
                          ("CODE_SIGN_IDENTITY", '"-"'), ("SKIP_INSTALL", "YES"), ("TEST_HOST", '""')]
            else:
                extra += [("SKIP_INSTALL", "YES")]
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
               BlueprintName = "{target}" ReferencedContainer = "container:Oizys.xcodeproj" />
         </BuildActionEntry>
         <BuildActionEntry buildForTesting="YES" buildForRunning="NO" buildForProfiling="NO"
                           buildForArchiving="NO" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_id}"
              BuildableName="OizysTests.xctest" BlueprintName="OizysTests" ReferencedContainer="container:Oizys.xcodeproj" />
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
               selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
               shouldUseLaunchSchemeArgsEnv = "YES">
      <MacroExpansion>
         <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_id}"
           BuildableName="{product}" BlueprintName="{target}" ReferencedContainer="container:Oizys.xcodeproj" />
      </MacroExpansion>
      <Testables>
         <TestableReference skipped="NO">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_id}"
              BuildableName="OizysTests.xctest" BlueprintName="OizysTests" ReferencedContainer="container:Oizys.xcodeproj" />
         </TestableReference>
      </Testables>
      <EnvironmentVariables>
         <EnvironmentVariable key="OIZYS_DYLIB" value="$(BUILT_PRODUCTS_DIR)/libOizysCore.dylib" isEnabled="YES" />
      </EnvironmentVariables>
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
            BlueprintName = "{target}" ReferencedContainer = "container:Oizys.xcodeproj" />
      </BuildableProductRunnable>
      <CommandLineArguments>
{arguments}
      </CommandLineArguments>
   </LaunchAction>
   <ProfileAction buildConfiguration = "{profile_config}" shouldUseLaunchSchemeArgsEnv = "YES"
                  savedToolIdentifier = "" useCustomWorkingDirectory = "YES"
                  customWorkingDirectory = "$(SRCROOT)" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary"
            BlueprintIdentifier = "{target_id}" BuildableName = "{product}"
            BlueprintName = "{target}" ReferencedContainer = "container:Oizys.xcodeproj" />
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug" />
   <ArchiveAction buildConfiguration = "{archive_config}" revealArchiveInOrganizer = "YES" />
</Scheme>
"""


def argument(value, enabled="YES"):
    return (f'         <CommandLineArgument argument = "{value}" '
            f'isEnabled = "{enabled}" />')


def main():
    PROJECT.mkdir(parents=True, exist_ok=True)
    (PROJECT / "project.pbxproj").write_text(build())

    scheme_dir = PROJECT / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)

    schemes = {
        # Run drives the live driver; Profile builds the frame-pointer configuration so
        # Instruments can walk the encoder's stack.
        "oizys": ("oizys", "DebugMinimal", [argument("monitors")]),
        "Oizys-production": ("Oizys.app", "Production", [argument("--background")]),
        "Oizys-production-fallback": ("Oizys.app", "ProductionFallback", [argument("--background")]),
        "Oizys-debug": ("Oizys-debug.app", "DebugMinimal", []),
        "Oizys-debug-verbose": ("Oizys-debug.app", "DebugVerbose", []),
        "Oizys-debug-fallback": ("Oizys-debug.app", "DebugFallback", []),
        "oizys-live-profile": ("oizys", "Profile", [argument("serve"), argument("--takeover"), argument("--stats")]),
        "oizys-profile": ("oizys", "Profile", [argument("profile")]),
        "OizysCoreDylib": ("libOizysCore.dylib", "Debug", []),
    }
    for name, (product, launch_config, arguments) in schemes.items():
        target = "OizysApp" if product.endswith(".app") else "oizys" if product == "oizys" else "OizysCoreDylib"
        (scheme_dir / f"{name}.xcscheme").write_text(SCHEME.format(
            target_id=oid("target", target), target=target, product=product,
            launch_config=launch_config, arguments="\n".join(arguments), test_id=oid("target", "OizysTests"),
            profile_config=(launch_config + "Profile" if launch_config.startswith("Production") else launch_config) if target == "OizysApp" else "Profile",
            archive_config=launch_config if target == "OizysApp" else "Release"))

    print(f"wrote {PROJECT.relative_to(ROOT)}: "
          f"{len(core)} core sources, {len(tool_sources())} tool sources, "
          f"{len(schemes)} schemes" if (core := core_sources()) else "")


if __name__ == "__main__":
    main()
