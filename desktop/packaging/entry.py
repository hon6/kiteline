"""打包版入口（PyInstaller 用）"""
import sys

from kiteline.__main__ import main

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
