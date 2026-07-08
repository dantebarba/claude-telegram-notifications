#!/usr/bin/env python3
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import tg_config


def usage_error():
    print("error: usage: /notifications | /notifications auto <seconds> | /notifications auto off")


def main(argv):
    state_dir = tg_config.get_state_dir()
    config = tg_config.load_config(state_dir)

    if not argv:
        config["enabled"] = not config.get("enabled", False)
        tg_config.save_config(state_dir, config)
        print("enabled" if config["enabled"] else "disabled")
        return

    if len(argv) == 2 and argv[0] == "auto":
        if argv[1] == "off":
            config["auto_seconds"] = None
            tg_config.save_config(state_dir, config)
            print("auto-disabled")
            return

        try:
            seconds = int(argv[1])
        except ValueError:
            usage_error()
            return

        if seconds <= 0:
            usage_error()
            return

        config["auto_seconds"] = seconds
        config["enabled"] = True
        tg_config.save_config(state_dir, config)
        print(f"auto-enabled:{seconds}")
        return

    usage_error()


if __name__ == "__main__":
    main(sys.argv[1:])
