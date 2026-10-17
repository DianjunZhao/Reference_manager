"""Read the product identity from the Xcode project's app build settings."""

import re
from pathlib import Path


def current_product_identity(project_root):
    project_root = Path(project_root)
    project_file = project_root / "LatticeLens.xcodeproj" / "project.pbxproj"
    try:
        source = project_file.read_text(encoding="utf-8")
    except OSError as error:
        raise ValueError("cannot read Xcode project release identity: " + str(error)) from error

    def one_value(key):
        values = {
            match.strip().strip('"')
            for match in re.findall(r"(?m)\b" + re.escape(key) + r"\s*=\s*([^;]+);", source)
        }
        if len(values) != 1:
            raise ValueError("Xcode project must define one consistent " + key)
        return next(iter(values))

    product_version = one_value("MARKETING_VERSION")
    bundle_version = one_value("INFOPLIST_KEY_CFBundleShortVersionString")
    build_number = one_value("CURRENT_PROJECT_VERSION")
    bundle_build_number = one_value("INFOPLIST_KEY_CFBundleVersion")
    if product_version != bundle_version:
        raise ValueError("Xcode marketing and bundle short versions disagree")
    if not build_number.isdecimal() or build_number != bundle_build_number:
        raise ValueError("Xcode project and bundle build numbers disagree")
    return product_version, int(build_number)
