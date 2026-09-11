import os
import zipfile

PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT_ZIP = os.path.join(PROJECT_ROOT, "mac_android_filemanager_v2.zip")

def make_archive():
    print(f"Creating project ZIP archive at: {OUTPUT_ZIP}")
    with zipfile.ZipFile(OUTPUT_ZIP, "w", zipfile.ZIP_DEFLATED) as zipf:
        for root, dirs, files in os.walk(PROJECT_ROOT):
            # Пропускаем build артефакты, кэш и git
            if ".git" in root or ".build" in root or "build" in root or ".cache" in root:
                continue
            for file in files:
                if file.endswith(".zip") or file.endswith(".db"):
                    continue
                file_path = os.path.join(root, file)
                rel_path = os.path.relpath(file_path, PROJECT_ROOT)
                zipf.write(file_path, rel_path)
                print(f"  + Packing: {rel_path}")
    print(f"\n[OK] Archive successfully generated: {OUTPUT_ZIP}")

if __name__ == "__main__":
    make_archive()
