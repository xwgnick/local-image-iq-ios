"""Read-only, stdlib-only branding contract checks; run after assets are generated.

No asset generation, Pillow imports, subprocesses, network or model loads. PNG
checks inspect headers/chunk framing, not decoded pixels. Source SHA-256 checks
establish selected-file identity, NOT output RGB/pixel preservation. Swift/YAML
checks target the current source layout, not full language parsing; these tests
do not replace Xcode asset/storyboard compilation or device/UI validation.
"""

from __future__ import annotations

import fnmatch
import hashlib
import json
from pathlib import Path
import plistlib
import re
import struct
import unittest
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "App" / "Assets.xcassets"
BRANDING = ROOT / "Resources" / "Branding"
SOURCE_PATH = "Resources/Branding/B02-selected.png"
SOURCE_SHA256 = "5c5dd3cfb41febfccdffbd4feacaf5e9033d8d9c49a26d3551a74f3f70b4500f"
LOGO_POINTS = 192
OUTPUTS = {
    "App/Assets.xcassets/AppIcon.appiconset/AppIcon.png": (1024, "RGB", 2),
    "App/Assets.xcassets/LaunchLogo.imageset/LaunchLogo.png": (192, "RGBA", 6),
    "App/Assets.xcassets/LaunchLogo.imageset/LaunchLogo@2x.png": (384, "RGBA", 6),
    "App/Assets.xcassets/LaunchLogo.imageset/LaunchLogo@3x.png": (576, "RGBA", 6),
}


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def swift_source(path: Path) -> str:
    """Ignore ordinary comments without deleting // inside quoted strings."""
    return re.sub(
        r'"(?:\\.|[^"\\])*"|//[^\n]*|/\*.*?\*/',
        lambda match: match[0] if match[0].startswith('"') else "\n" * match[0].count("\n") + " ",
        path.read_text(encoding="utf-8-sig"),
        flags=re.DOTALL,
    )


class BrandingTests(unittest.TestCase):
    def swift_block(self, source: str, declaration: str) -> str:
        """Read one current brace-delimited block, ignoring braces in strings."""
        match = re.search(declaration + r"\s*\{", source)
        self.assertIsNotNone(match, declaration)
        assert match is not None
        depth = 1
        for token in re.finditer(r'"(?:\\.|[^"\\])*"|[{}]', source[match.end():]):
            if token[0] == "{":
                depth += 1
            elif token[0] == "}":
                depth -= 1
            if depth == 0:
                return source[match.end():match.end() + token.start()]
        self.fail(f"Unclosed Swift block: {declaration}")

    def png_info(self, path: Path):
        """Read IHDR and walk chunk boundaries so tRNS means a real PNG chunk."""
        self.assertTrue(path.is_file(), f"Missing generated asset: {path}")
        data = path.read_bytes()
        self.assertEqual(data[:8], b"\x89PNG\r\n\x1a\n", str(path))
        offset = 8
        chunks = []
        header = None
        while offset < len(data):
            self.assertGreaterEqual(len(data) - offset, 12, f"Truncated PNG chunk: {path}")
            length, kind = struct.unpack_from(">I4s", data, offset)
            end = offset + 12 + length  # Length, type, payload and CRC.
            self.assertLessEqual(end, len(data), f"Truncated {kind!r}: {path}")
            if not chunks:
                self.assertEqual(kind, b"IHDR", str(path))
            if kind == b"IHDR":
                self.assertIsNone(header, f"Duplicate IHDR: {path}")
                self.assertEqual(length, 13, str(path))
                width, height, depth, color, compression, filtering, interlace = struct.unpack_from(
                    ">IIBBBBB", data, offset + 8
                )
                self.assertGreater(width, 0)
                self.assertGreater(height, 0)
                self.assertEqual((compression, filtering), (0, 0))
                self.assertIn(interlace, (0, 1))
                header = (width, height, depth, color)
            chunks.append(kind)
            offset = end
            if kind == b"IEND":
                self.assertEqual(length, 0)
                self.assertEqual(offset, len(data), f"Trailing bytes after IEND: {path}")
                break
        self.assertIsNotNone(header, str(path))
        self.assertIn(b"IDAT", chunks, str(path))
        self.assertEqual(chunks[-1], b"IEND", str(path))
        return header, chunks

    def storyboard(self):
        document = ET.parse(ROOT / "App" / "LaunchScreen.storyboard").getroot()
        controllers = document.findall("./scenes/scene/objects/viewController")
        self.assertEqual(len(controllers), 1)
        root_view = controllers[0].find("./view")
        self.assertIsNotNone(root_view)
        assert root_view is not None
        logos = root_view.findall("./subviews/imageView")
        self.assertEqual(len(logos), 1)
        return document, controllers[0], root_view, logos[0]

    def yaml_block(self, text: str, heading: str) -> str:
        """Extract one current indentation-based block, without requiring PyYAML."""
        matches = list(re.finditer(r"(?m)^( *)" + re.escape(heading) + r"[ \t]*$", text))
        # Scheme build/test blocks also contain targets:. Select the outermost
        # occurrence within the current block, not a nested same-name key.
        if matches:
            shallowest = min(len(match[1]) for match in matches)
            matches = [match for match in matches if len(match[1]) == shallowest]
        self.assertEqual(len(matches), 1, f"Expected one YAML heading: {heading}")
        match = matches[0]
        indent = len(match[1])
        lines = []
        for line in text[match.end():].splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            if len(line) - len(line.lstrip(" ")) <= indent:
                break
            lines.append(line)
        return "\n".join(lines)

    def test_info_plist_launch_and_status_bar_contract(self):
        payload = (ROOT / "App" / "Info.plist").read_bytes()
        self.assertEqual(ET.fromstring(payload).tag, "plist")
        info = plistlib.loads(payload, fmt=plistlib.FMT_XML)
        self.assertEqual(info["UILaunchStoryboardName"], "LaunchScreen")
        self.assertNotIn("UILaunchScreen", info)
        self.assertIs(info["UIStatusBarHidden"], True)
        self.assertIs(info["UIViewControllerBasedStatusBarAppearance"], True)

    def test_project_includes_branding_resources_and_app_icon(self):
        project = (ROOT / "project.yml").read_text(encoding="utf-8-sig")
        target = self.yaml_block(self.yaml_block(project, "targets:"), "LocalImageIQ:")
        settings = self.yaml_block(self.yaml_block(target, "settings:"), "base:")
        self.assertRegex(settings, r"(?m)^\s*ASSETCATALOG_COMPILER_APPICON_NAME:\s*AppIcon[ \t]*$")
        self.assertRegex(settings, r"(?m)^\s*INFOPLIST_FILE:\s*App/Info\.plist[ \t]*$")
        app = self.yaml_block(self.yaml_block(target, "sources:"), "- path: App")
        # The current spec uses an inline exclusion list and recursive App discovery.
        exclusions = re.findall(r"(?m)^\s*excludes:[ \t]*\[([^\]\n]*)\][ \t]*$", app)
        self.assertEqual(len(exclusions), 1, "Review resource discovery if YAML structure changes")
        self.assertNotRegex(app, r"(?m)^\s*(?:includes|buildPhase):")
        patterns = [item.strip().strip("\"'") for item in exclusions[0].split(",") if item.strip()]
        resources = ["LaunchScreen.storyboard", "Assets.xcassets/Contents.json"]
        resources.extend(path.removeprefix("App/") for path in OUTPUTS)
        for relative in resources:
            with self.subTest(resource=relative):
                self.assertTrue((ROOT / "App" / relative).is_file())
                parts = Path(relative).parts
                candidates = ["/".join(parts[:index]) for index in range(1, len(parts) + 1)]
                self.assertFalse(any(fnmatch.fnmatchcase(name, pattern)
                                     for name in candidates for pattern in patterns))

    def test_storyboard_is_one_image_without_text_or_progress(self):
        document, controller, root_view, logo = self.storyboard()
        self.assertEqual(document.tag, "document")
        self.assertEqual(document.get("launchScreen"), "YES")
        self.assertEqual(document.get("useAutolayout"), "YES")
        self.assertEqual(document.get("initialViewController"), controller.get("id"))
        self.assertEqual(len(document.findall("./scenes/scene")), 1)
        self.assertEqual(document.findall(".//imageView"), [logo])
        self.assertEqual(root_view.findall(".//subviews/*"), [logo])
        self.assertEqual(logo.get("image"), "LaunchLogo")
        self.assertEqual(logo.get("contentMode"), "scaleAspectFit")
        self.assertEqual(logo.get("translatesAutoresizingMaskIntoConstraints"), "NO")
        forbidden = {"label", "textField", "textView", "button", "activityIndicatorView", "progressView"}
        self.assertFalse(forbidden.intersection(node.tag for node in document.iter()))

    def test_storyboard_geometry_matches_startup_appearance_and_root_center(self):
        document, _, root_view, logo = self.storyboard()
        source = swift_source(ROOT / "App" / "UI" / "StartupView.swift")
        appearance = re.search(r"\benum\s+StartupAppearance\s*\{([^}]+)\}", source)
        self.assertIsNotNone(appearance)
        assert appearance is not None
        for name, value in (("imageName", "LaunchLogo"), ("backgroundName", "LaunchBackground")):
            self.assertRegex(appearance[1], rf'\bstatic\s+let\s+{name}\s*=\s*"{value}"')
        size = re.search(r"\bstatic\s+let\s+iconSize\s*:\s*CGFloat\s*=\s*(\d+(?:\.\d+)?)\b", appearance[1])
        self.assertIsNotNone(size)
        assert size is not None
        self.assertEqual(float(size[1]), LOGO_POINTS)
        self.assertEqual(len(document.findall(".//constraint")), 4)
        dimensions = logo.findall("./constraints/constraint")
        self.assertEqual(len(dimensions), 2)
        self.assertEqual({node.get("firstAttribute") for node in dimensions}, {"width", "height"})
        for node in dimensions:
            self.assertEqual(float(node.get("constant", "0")), float(size[1]))
            self.assertIn(node.get("firstItem"), (None, logo.get("id")))
            self.assertIsNone(node.get("secondItem"))
        centers = root_view.findall("./constraints/constraint")
        self.assertEqual(len(centers), 2)
        self.assertEqual({node.get("firstAttribute") for node in centers}, {"centerX", "centerY"})
        for node in centers:
            self.assertEqual(node.get("firstItem"), logo.get("id"))
            self.assertEqual(node.get("secondItem"), root_view.get("id"), "Must center on root, not safe area")
            self.assertEqual(node.get("secondAttribute"), node.get("firstAttribute"))
            self.assertEqual(float(node.get("constant", "0")), 0)
        for node in dimensions + centers:
            self.assertEqual(node.get("relation", "equal"), "equal")
            self.assertEqual(float(node.get("multiplier", "1")), 1)
            self.assertEqual(float(node.get("priority", "1000")), 1000)
        image = document.find('./resources/image[@name="LaunchLogo"]')
        self.assertIsNotNone(image)
        assert image is not None
        self.assertEqual((float(image.attrib["width"]), float(image.attrib["height"])), (LOGO_POINTS, LOGO_POINTS))

    def test_app_icon_catalog_and_opaque_rgb_png(self):
        folder = CATALOG / "AppIcon.appiconset"
        catalog = read_json(folder / "Contents.json")
        self.assertEqual(catalog["info"]["version"], 1)
        self.assertEqual(catalog["images"], [
            {"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}
        ])
        header, chunks = self.png_info(folder / catalog["images"][0]["filename"])
        self.assertEqual(header, (1024, 1024, 8, 2))
        self.assertNotIn(b"tRNS", chunks, "RGB app icon must not have keyed transparency")

    def test_launch_logo_catalog_scales_and_rgba_pngs(self):
        folder = CATALOG / "LaunchLogo.imageset"
        catalog = read_json(folder / "Contents.json")
        self.assertEqual(catalog["info"]["version"], 1)
        self.assertEqual(len(catalog["images"]), 3)
        images = {image["scale"]: image for image in catalog["images"]}
        self.assertEqual(set(images), {"1x", "2x", "3x"})
        for scale, filename, size in (("1x", "LaunchLogo.png", 192),
                                     ("2x", "LaunchLogo@2x.png", 384),
                                     ("3x", "LaunchLogo@3x.png", 576)):
            with self.subTest(scale=scale):
                self.assertEqual(images[scale]["idiom"], "universal")
                self.assertEqual(images[scale]["filename"], filename)
                header, chunks = self.png_info(folder / filename)
                self.assertEqual(header, (size, size, 8, 6))
                self.assertNotIn(b"tRNS", chunks, "RGBA uses its alpha channel, not tRNS")

    def test_adaptive_background_and_storyboard_color_reference(self):
        catalog = read_json(CATALOG / "LaunchBackground.colorset" / "Contents.json")
        self.assertEqual(catalog["info"]["version"], 1)
        self.assertEqual(len(catalog["colors"]), 2)
        light = [entry for entry in catalog["colors"] if not entry.get("appearances")]
        dark = [entry for entry in catalog["colors"] if entry.get("appearances") == [
            {"appearance": "luminosity", "value": "dark"}
        ]]
        self.assertEqual((len(light), len(dark)), (1, 1))
        components = []
        for entry in (light[0], dark[0]):
            self.assertEqual(entry["idiom"], "universal")
            self.assertEqual(entry["color"]["color-space"], "srgb")
            rgba = tuple(float(entry["color"]["components"][key]) for key in ("red", "green", "blue", "alpha"))
            self.assertTrue(all(0 <= value <= 1 for value in rgba))
            self.assertEqual(rgba[3], 1)
            components.append(rgba)
        self.assertNotEqual(components[0][:3], components[1][:3])
        document, _, root_view, _ = self.storyboard()
        background = root_view.find('./color[@key="backgroundColor"]')
        fallback = document.find('./resources/namedColor[@name="LaunchBackground"]/color')
        self.assertIsNotNone(background)
        self.assertIsNotNone(fallback)
        assert background is not None and fallback is not None
        self.assertEqual(background.get("name"), "LaunchBackground")
        for key, value in zip(("red", "green", "blue", "alpha"), components[0]):
            self.assertAlmostEqual(float(fallback.attrib[key]), value, places=6)

    def test_manifest_pins_the_selected_source_identity(self):
        manifest = read_json(BRANDING / "manifest.json")
        self.assertEqual(manifest["source"], SOURCE_PATH)
        self.assertEqual(manifest["source_sha256"], SOURCE_SHA256)
        source = ROOT / SOURCE_PATH
        self.assertTrue(source.is_file())
        self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(), SOURCE_SHA256)
        # This is provenance only, not a claim about output RGB preservation.

    def test_manifest_has_exact_outputs_with_actual_hashes_and_dimensions(self):
        manifest = read_json(BRANDING / "manifest.json")
        self.assertEqual(manifest["launch_size_points"], LOGO_POINTS)
        entries = manifest["outputs"]
        self.assertEqual(len(entries), 4)
        self.assertEqual({entry["path"] for entry in entries}, set(OUTPUTS))
        for entry in entries:
            with self.subTest(path=entry["path"]):
                size, mode, color_type = OUTPUTS[entry["path"]]
                path = ROOT / entry["path"]
                header, _ = self.png_info(path)
                self.assertEqual(header, (size, size, 8, color_type))
                self.assertEqual(entry["dimensions"], list(header[:2]))
                self.assertEqual(entry["mode"], mode)
                self.assertRegex(entry["sha256"], r"\A[0-9a-f]{64}\Z")
                self.assertEqual(entry["sha256"], hashlib.sha256(path.read_bytes()).hexdigest())

    def test_startup_uses_only_brand_image_and_background_not_visible_text(self):
        source = swift_source(ROOT / "App" / "UI" / "StartupView.swift")
        self.assertEqual(len(re.findall(r"\bImage\s*\(", source)), 1)
        self.assertRegex(source, r"\bImage\s*\(\s*StartupAppearance\.imageName\s*\)")
        self.assertRegex(source, r"\bColor\s*\(\s*StartupAppearance\.backgroundName\s*\)")
        self.assertRegex(source, r"\.frame\s*\(\s*width:\s*StartupAppearance\.iconSize\s*,\s*height:\s*StartupAppearance\.iconSize\s*\)")
        self.assertRegex(source, r"\.renderingMode\s*\(\s*\.original\s*\)")
        self.assertRegex(source, r"\.scaledToFit\s*\(\s*\)")
        self.assertRegex(source, r"\.ignoresSafeArea\s*\(\s*\)")
        # Named accessibility actions legitimately construct Text; remove only
        # that argument, not their closures or other Text elsewhere in the view.
        visible = re.sub(
            r'\.accessibilityAction\s*\(\s*named\s*:\s*Text\s*\(\s*"(?:\\.|[^"\\])*"\s*\)\s*\)',
            ".accessibilityAction",
            source,
        )
        self.assertNotRegex(visible, r"\b(?:Text|Label|TextField|SecureField|TextEditor|ProgressView|Gauge)\s*(?:\(|\{)")
        self.assertNotRegex(source, r"\b(?:systemName|systemImage)\s*:")
        self.assertNotRegex(source, r"\b(?:Circle|Ellipse|RoundedRectangle|Path|Canvas|GeometryReader|TimelineView|KeyframeAnimator|PhaseAnimator)\b")
        self.assertNotRegex(source, r"\.(?:animation|transition|contentTransition|repeatForever|symbolEffect)\s*\(")
        self.assertNotRegex(source, r"\b(?:withAnimation|withTransaction)\s*(?:\(|\{)")
        self.assertNotRegex(source, r"@(?:State|StateObject)|\.(?:task|onAppear|onChange|onReceive)\s*(?:\(|\{)")

        # The ONLY visible-progress exception is the approved deterministic
        # capsule. Do not exempt a whole file/component from the guards above.
        bar = self.swift_block(source, r"struct\s+StartupStepProgressBar\s*:\s*View")
        body = self.swift_block(bar, r"var\s+body\s*:\s*some\s+View")
        expected_body = '''
            ZStack(alignment: .leading) {
                Capsule().fill(IQStyle.line)
                if fillWidth > 0 {
                    Capsule().fill(IQStyle.accent)
                        .frame(width: fillWidth)
                }
            }
            .frame(width: StartupAppearance.progressWidth, height: StartupAppearance.progressHeight)
            .clipShape(Capsule())
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("启动准备进度")
            .accessibilityValue(accessibilityProgress)
            .accessibilityIdentifier("startup-step-progress")
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        '''
        self.assertEqual(re.sub(r"\s+", "", body), re.sub(r"\s+", "", expected_body))
        outside_bar = source.replace(bar, "", 1)
        self.assertNotRegex(outside_bar, r"\bCapsule\s*\(")
        without_hit_target = re.sub(r"\.contentShape\(Rectangle\(\)\)", "", outside_bar)
        self.assertNotRegex(without_hit_target, r"\bRectangle\s*\(")
        self.assertNotRegex(source, r"\b(?:VStack|HStack|Spacer)\s*\(|\.(?:padding|position)\s*\(")
        for name, value in (("progressWidth", 144), ("progressHeight", 3), ("progressGap", 28)):
            self.assertRegex(source, rf"\bstatic\s+let\s+{name}\s*:\s*CGFloat\s*=\s*{value}\b")
        self.assertRegex(bar, r"guard\s+let\s+fraction,\s*fraction\.isFinite\s+else\s*\{\s*return\s+nil\s*\}")
        self.assertRegex(bar, r"return\s+min\(max\(fraction,\s*0\),\s*1\)")
        self.assertRegex(bar, r"StartupAppearance\.progressWidth\s*\*\s*CGFloat\(Self\.sanitizedFraction\(fraction\)\s*\?\?\s*0\)")

        content = self.swift_block(source, r"struct\s+StartupContent\s*:\s*View")
        self.assertRegex(content, r"onOpenHome:\s*@escaping\s*\(\)\s*->\s*Void,\s*progressFraction:\s*Double\?\s*=\s*nil\s*\)")
        gate = self.swift_block(content, r"var\s+visibleProgressFraction\s*:\s*Double\?")
        self.assertRegex(gate, r"\A\s*guard\s+phase\s*==\s*\.checkingLibrary\s*\|\|\s*phase\s*==\s*\.preparingSearch\s+else\s*\{\s*return\s+nil\s*\}\s*return\s+StartupStepProgressBar\.sanitizedFraction\(progressFraction\)\s*\Z")
        self.assertRegex(source, r"progressFraction:\s*state\.startupProgressFraction\s*\)")
        self.assertEqual(len(re.findall(r"\bStartupStepProgressBar\s*\(", source)), 1)
        self.assertEqual(len(re.findall(r"\.offset\s*\(", source)), 1)
        self.assertRegex(content, r"\.frame\(maxWidth:\s*\.infinity,\s*maxHeight:\s*\.infinity\)\s*\.overlay\(alignment:\s*\.center\)\s*\{\s*if\s+let\s+fraction\s*=\s*visibleProgressFraction\s*\{\s*StartupStepProgressBar\(fraction:\s*fraction\)\s*\.offset\(y:\s*StartupAppearance\.iconSize\s*/\s*2\s*\+\s*StartupAppearance\.progressGap\s*\+\s*StartupAppearance\.progressHeight\s*/\s*2\)\s*\}\s*\}\s*\.ignoresSafeArea\(\)")
        self.assertRegex(content, r"\.transaction\s*\{\s*transaction\s+in\s+transaction\.animation\s*=\s*nil\s+transaction\.disablesAnimations\s*=\s*true\s*\}")

        # Original exclusive long-press/tap and all three VoiceOver actions stay
        # on the failure icon. The new bar must introduce no recovery action.
        self.assertRegex(content, r"if\s+canRecover\s*\{\s*logo\s*\.contentShape\(Rectangle\(\)\)\s*\.gesture\(LongPressGesture\(minimumDuration:\s*1\)\.exclusively\(before:\s*TapGesture\(\)\)\s*\.onEnded\(handleRecoveryGesture\)\)")
        self.assertRegex(content, r"var\s+canRecover:\s*Bool\s*\{\s*phase\s*==\s*\.failed\s*\}")
        for action in ("retryIfFailed", "openHomeIfFailed"):
            self.assertRegex(content, rf"func\s+{action}\(\)\s*\{{\s*guard\s+canRecover\s+else\s*\{{\s*return\s*\}}")
        self.assertIn('.accessibilityAction { retryIfFailed() }', content)
        self.assertIn('.accessibilityAction(named: Text("重试")) { retryIfFailed() }', content)
        self.assertIn('.accessibilityAction(named: Text("先进入应用")) { openHomeIfFailed() }', content)
        self.assertEqual(len(re.findall(r"\.accessibilityAction\b", source)), 3)
        self.assertEqual(len(re.findall(r"\.gesture\s*\(", source)), 1)
        self.assertNotRegex(source, r"\.(?:onTapGesture|onLongPressGesture|simultaneousGesture|highPriorityGesture)\s*(?:\(|\{)")

    def test_root_keeps_ready_gate_real_start_task_and_status_bar_rule(self):
        source = swift_source(ROOT / "App" / "LocalImageIQApp.swift")
        self.assertRegex(source, r"if\s+state\.launchPhase\s*==\s*\.ready\s*\{\s*ContentView\(\s*state:\s*state\s*\)\s*\}\s*else\s*\{\s*StartupView\(\s*state:\s*state\s*\)\s*\}")
        self.assertRegex(source, r"\.task\s*\{\s*state\.start\(\s*\)\s*\}")
        self.assertRegex(source, r"\.statusBarHidden\s*\(\s*state\.launchPhase\s*!=\s*\.ready\s*\)")
        self.assertNotRegex(source, r"\bstate\.launchPhase\s*=(?!=)")

    def test_launch_presentation_has_no_artificial_delay_calls(self):
        delay = re.compile(
            r"\b(?:Task|Thread)\s*\.\s*sleep\b"
            r"|\b(?:sleep|usleep|nanosleep)\s*\("
            r"|\.\s*(?:asyncAfter|delay)\s*\("
            r"|\bTimer\s*\.\s*(?:scheduledTimer|publish)\s*\("
        )
        # A recovery LongPressGesture's minimumDuration is not a launch delay.
        for relative in ("App/UI/StartupView.swift", "App/LocalImageIQApp.swift"):
            with self.subTest(file=relative):
                self.assertNotRegex(swift_source(ROOT / relative), delay)
        startup = swift_source(ROOT / "App" / "UI" / "StartupView.swift")
        self.assertNotRegex(startup, r"\b(?:Timer|CADisplayLink|TimelineView|Date|ContinuousClock|SuspendingClock|DispatchQueue|Task|Thread)\b")
        self.assertNotRegex(startup, r"\b(?:timeIntervalSince|systemUptime|elapsed|deadline)\w*\b")


if __name__ == "__main__":
    unittest.main()