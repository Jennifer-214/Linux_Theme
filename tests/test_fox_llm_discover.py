#!/usr/bin/env python3
"""tests/test_fox_llm_discover.py — fox-llm-discover's decisions, offline.

Hugging Face's API is replaced with canned answers; what is tested is the logic: one spelling per
model across quantizers, which file is picked, what is MoE, which uploads are left out (no tools, too
big, already yours), and the abliterated twin.
"""
import contextlib
import importlib.machinery
import importlib.util
import io
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
loader = importlib.machinery.SourceFileLoader("fox_llm_discover", str(ROOT / "shared/bin/fox-llm-discover"))
spec = importlib.util.spec_from_loader(loader.name, loader)
d = importlib.util.module_from_spec(spec)
loader.exec_module(d)

TOOLS = "{% if tools %}…{% endif %}"


def upload(repo, base, arch, params, template=TOOLS, created="2026-10-10"):
    return {"id": repo, "createdAt": created, "cardData": {"base_model": base},
            "gguf": {"architecture": arch, "total": params, "chat_template": template}}


def f(path, gb):
    return {"type": "file", "path": path, "size": int(gb * 1e9)}


class DiscoverTest(unittest.TestCase):
    def fake(self, uploads, trees, searches=None):
        """uploads: author → models; trees: repo → files; searches: query → models."""
        def get(url):
            if "/tree/main" in url:
                return trees[url.split("/api/models/", 1)[1].split("/tree/", 1)[0]]
            if "author=" in url:
                return uploads.get(url.split("author=", 1)[1].split("&", 1)[0], [])
            if "search=" in url:
                q = url.split("search=", 1)[1].split("&", 1)[0]
                return (searches or {}).get(q, [])
            raise AssertionError(url)
        d.get = get

    def run_main(self, *args):
        out = io.StringIO()
        old = sys.argv
        sys.argv = ["fox-llm-discover", *args]
        try:
            with contextlib.redirect_stdout(out):
                d.main()
        finally:
            sys.argv = old
        return [l.split("\t") for l in out.getvalue().splitlines()]

    def test_one_spelling_per_model_across_quantizers(self):
        for repo in ("unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF", "bartowski/Qwen_Qwen3-Coder-30B-A3B-Instruct-GGUF",
                     "Qwen/Qwen3-Coder-30B-A3B-Instruct", "ggml-org/Qwen3-Coder-30B-A3B-Instruct-Q8_0-GGUF"):
            self.assertEqual(d.key(repo), "qwen3-coder-30b-a3b", repo)
        self.assertEqual(d.key("huihui-ai/Huihui-Qwen3.6-35B-A3B-abliterated-GGUF"), "huihui-qwen3.6-35b-a3b-abliterated")

    def test_file_pick_prefers_q4_k_m_mxfp4_for_gpt_oss_and_skips_parts(self):
        self.fake({}, {
            "u/qwen": [f("Q-Q8_0.gguf", 30), f("Q-Q4_K_S.gguf", 17), f("Q-Q4_K_M.gguf", 18),
                       f("mmproj-F16.gguf", 0.9), f("MTP/mtp-Q4_0.gguf", 0.1)],
            "u/oss": [f("oss-Q4_K_M.gguf", 11.7), f("oss-MXFP4.gguf", 12.1)],
            "u/split": [f("S-Q4_K_M-00001-of-00002.gguf", 10)],
            "u/huge": [f("H-Q4_K_M.gguf", 40)],
        })
        self.assertEqual(d.pick_file("u/qwen", "qwen3moe", 24)[0], "Q-Q4_K_M.gguf")
        self.assertEqual(d.pick_file("u/oss", "gpt-oss", 24)[0], "oss-MXFP4.gguf")
        self.assertIsNone(d.pick_file("u/split", "qwen3", 24))
        self.assertIsNone(d.pick_file("u/huge", "qwen3", 24))

    def test_classes(self):
        self.assertEqual(d.classify("qwen3-coder-30b-a3b", "qwen3moe", 18, 9), "moe")
        self.assertEqual(d.classify("gpt-oss-20b", "gpt-oss", 12, 9), "moe")
        self.assertEqual(d.classify("lfm2.5-24b-a2b", "lfm2", 15, 9), "moe")          # from the name
        self.assertEqual(d.classify("qwen3.5-9b", "qwen35", 5.9, 9), "small")
        self.assertEqual(d.classify("qwen3.6-27b", "qwen35", 17, 9), "slow")

    def test_report_newest_first_without_yours_tools_or_misfits(self):
        self.fake(
            uploads={
                "ggml-org": [upload("ggml-org/New-MoE-24B-A2B-GGUF", "lab/New-MoE-24B-A2B", "lfm2moe", 24e9, created="2026-10-13"),
                             upload("ggml-org/Image-Thing-GGUF", "lab/Image-Thing", "qwen_image", 7e9, template=""),
                             upload("ggml-org/Giant-GGUF", "lab/Giant", "glm5", 700e9)],
                "unsloth": [upload("unsloth/New-MoE-24B-A2B-GGUF", "lab/New-MoE-24B-A2B", "lfm2moe", 24e9, created="2026-10-14"),
                            upload("unsloth/Small-9B-GGUF", "lab/Small-9B", "qwen35", 9e9, created="2026-10-01"),
                            upload("unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF", "Qwen/Qwen3-Coder-30B-A3B-Instruct", "qwen3moe", 30e9)],
            },
            trees={"ggml-org/New-MoE-24B-A2B-GGUF": [f("New-MoE-24B-A2B-Q4_K_M.gguf", 14.9)],
                   "unsloth/Small-9B-GGUF": [f("Small-9B-Q4_K_M.gguf", 5.9)],
                   "huihui-ai/Huihui-New-MoE-24B-A2B-abliterated-GGUF": [f("x-Q4_K_M.gguf", 15)]},
            searches={"New-MoE-24B-A2B-abliterated": [{"id": "random/New-MoE-24B-A2B-abliterated-GGUF"},
                                                      {"id": "huihui-ai/Huihui-New-MoE-24B-A2B-abliterated-GGUF"}]})
        have = Path(self._testMethodName + ".have")
        have.write_text("unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q4_K_M.gguf\n")
        try:
            rows = self.run_main("--max-gb", "24", "--have", str(have))
        finally:
            have.unlink()
        self.assertEqual([r[0] for r in rows], ["new-moe-24b-a2b", "small-9b"])        # newest first
        moe = rows[0]
        self.assertEqual(moe[1], "ggml-org/New-MoE-24B-A2B-GGUF/New-MoE-24B-A2B-Q4_K_M.gguf")   # llama.cpp's own first
        self.assertEqual((moe[2], moe[3]), ("14.9", "moe"))
        self.assertEqual(moe[4:], ["huihui-new-moe-24b-a2b-abliterated",
                                   "huihui-ai/Huihui-New-MoE-24B-A2B-abliterated-GGUF/x-Q4_K_M.gguf"])  # Huihui's only
        self.assertEqual(rows[1][3:], ["small", "-", "-"])


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False, verbosity=1).result.wasSuccessful() else 1)
