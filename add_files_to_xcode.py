#!/usr/bin/env python3
"""
Add SpeechModelManager.swift and SpeechModelPromptView.swift to Xcode project
"""

import uuid
import re

PROJECT_PATH = "Murmur.xcodeproj/project.pbxproj"

# Generate unique IDs for Xcode (24-character hex strings)
def generate_id():
    return uuid.uuid4().hex[:24].upper()

# IDs for new files
speech_model_manager_ref = generate_id()
speech_model_manager_build = generate_id()
speech_model_prompt_view_ref = generate_id()
speech_model_prompt_view_build = generate_id()

# Read the project file
with open(PROJECT_PATH, 'r') as f:
    content = f.read()

# 1. Add PBXBuildFile entries (after the existing ones)
build_file_section = "/* End PBXBuildFile section */"
new_build_files = f"""		{speech_model_manager_build} /* SpeechModelManager.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {speech_model_manager_ref} /* SpeechModelManager.swift */; }};
		{speech_model_prompt_view_build} /* SpeechModelPromptView.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {speech_model_prompt_view_ref} /* SpeechModelPromptView.swift */; }};
/* End PBXBuildFile section */"""

content = content.replace(build_file_section, new_build_files)

# 2. Add PBXFileReference entries
file_ref_section = "/* End PBXFileReference section */"
new_file_refs = f"""		{speech_model_manager_ref} /* SpeechModelManager.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SpeechModelManager.swift; sourceTree = "<group>"; }};
		{speech_model_prompt_view_ref} /* SpeechModelPromptView.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = SpeechModelPromptView.swift; sourceTree = "<group>"; }};
/* End PBXFileReference section */"""

content = content.replace(file_ref_section, new_file_refs)

# 3. Add to Core group (A1000024)
# Find the Core group and add SpeechModelManager.swift
core_group_pattern = r"(A1000024 /\* Core \*/ = \{[^}]+children = \([^)]+)(A1000014 /\* Clipboard\.swift \*/,)"
core_replacement = r"\1\2\n				{} /* SpeechModelManager.swift */,".format(speech_model_manager_ref)
content = re.sub(core_group_pattern, core_replacement, content)

# 4. Add to UI group (A1000025)
# Find the UI group and add SpeechModelPromptView.swift
ui_group_pattern = r"(A1000025 /\* UI \*/ = \{[^}]+children = \([^)]+)(A1000010 /\* Settings\.swift \*/,)"
ui_replacement = r"\1\2\n				{} /* SpeechModelPromptView.swift */,".format(speech_model_prompt_view_ref)
content = re.sub(ui_group_pattern, ui_replacement, content)

# 5. Add to PBXSourcesBuildPhase (compile phase)
# Find the Sources build phase
sources_pattern = r"(PBXSourcesBuildPhase[^}]+files = \([^)]+)(A1000048 /\* TranscriptSaver\.swift in Sources \*/,)"
sources_replacement = r"\1\2\n				{} /* SpeechModelManager.swift in Sources */,\n				{} /* SpeechModelPromptView.swift in Sources */,".format(
    speech_model_manager_build, speech_model_prompt_view_build
)
content = re.sub(sources_pattern, sources_replacement, content)

# Write back
with open(PROJECT_PATH, 'w') as f:
    f.write(content)

print("✅ Successfully added files to Xcode project:")
print(f"   - SpeechModelManager.swift (ref: {speech_model_manager_ref})")
print(f"   - SpeechModelPromptView.swift (ref: {speech_model_prompt_view_ref})")
print("\nPlease rebuild in Xcode (Cmd+B)")
