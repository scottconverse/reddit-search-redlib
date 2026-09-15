import importlib.util
import json
import os
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "reddit_extract.py"
FIXTURES = Path(__file__).resolve().parent / "fixtures"
SPEC = importlib.util.spec_from_file_location("reddit_extract", SCRIPT)
MOD = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
sys.modules[SPEC.name] = MOD
SPEC.loader.exec_module(MOD)


class RedditExtractTests(unittest.TestCase):
    def test_rss_fixture(self):
        result = MOD.parse_rss((FIXTURES / "search.atom").read_text(encoding="utf-8"), "https://www.reddit.com/search.rss?q=redlib")
        self.assertEqual(result["source_adapter"], "reddit-rss")
        self.assertEqual(result["threads"][0]["id"], "abc123")
        self.assertEqual(result["threads"][0]["subreddit"], "foss")
        self.assertIn("Full body", result["threads"][0]["body_text"])

    def test_redlib_search_fixture(self):
        result = MOD.parse_redlib_search((FIXTURES / "search.html").read_text(encoding="utf-8"), "https://redlib.example/search?q=redlib")
        thread = result["threads"][0]
        self.assertEqual(thread["score"], 1234)
        self.assertEqual(thread["reported_comment_count"], 42)
        self.assertTrue(thread["canonical_reddit_url"].startswith("https://www.reddit.com/"))

    def test_redlib_thread_marks_partial(self):
        result = MOD.parse_redlib_thread((FIXTURES / "thread.html").read_text(encoding="utf-8"), "https://redlib.example/r/foss/comments/abc123/example/")
        thread = result["threads"][0]
        self.assertEqual(result["coverage"], "partial")
        self.assertEqual(thread["retrieved_comment_count"], 2)
        self.assertEqual(thread["comments"][1]["depth"], 1)
        self.assertEqual(thread["comments"][0]["score"], 25)

    def test_url_builder_encodes_query(self):
        completed = subprocess.run(
            [sys.executable, str(SCRIPT), "url", "redlib-search", "--base", "https://redlib.example", "--query", "a+b c", "--subreddit", "foss"],
            check=True,
            text=True,
            capture_output=True,
        )
        self.assertIn("q=a%2Bb+c", completed.stdout)
        self.assertIn("restrict_sr=on", completed.stdout)

    def test_invalid_html_fails_closed(self):
        with self.assertRaisesRegex(ValueError, "parse_failure"):
            MOD.parse_redlib_search("<html><title>challenge</title></html>", "https://redlib.example/search")

    def test_relative_comment_fragment_is_not_a_query_value(self):
        result = MOD.canonical_reddit_url('/r/foss/comments/abc123/post/c1/?context=3#c1')
        self.assertEqual(result, 'https://www.reddit.com/r/foss/comments/abc123/post/c1/?context=3')

    def test_sample_search_uses_discussion_titles_and_links(self):
        raw = (FIXTURES / 'sample-redlib-search-halo.raw').read_text(encoding='utf-8')
        result = MOD.parse_redlib_search(raw, 'http://127.0.0.1:18080/r/LocalLLaMA/search')
        self.assertEqual(len(result['threads']), 25)
        for thread in result['threads']:
            self.assertIn('/comments/' + thread['id'] + '/', thread['canonical_reddit_url'])
            self.assertNotIn(thread['title'], ['Resources', 'Discussion', 'Question | Help'])
        self.assertEqual(result['threads'][0]['id'], 'post01')
        self.assertIn('I compared five local runtimes', result['threads'][0]['title'])

    def test_sample_threads_metadata_comments_and_coverage(self):
        cases = [('thread-flash', 'post01', 23, 23),
                 ('thread-forks', 'post02', 35, 44),
                 ('thread-settings-redlib', 'post03', 22, 24)]
        for label, tid, retrieved, reported in cases:
            with self.subTest(label=label):
                raw = (FIXTURES / ('sample-' + label + '.raw')).read_text(encoding='utf-8')
                result = MOD.parse_redlib_thread(raw, f'http://127.0.0.1:18080/r/test/comments/{tid}/post/')
                thread = result['threads'][0]
                self.assertEqual(thread['id'], tid)
                self.assertEqual(thread['retrieved_comment_count'], retrieved)
                self.assertEqual(thread['reported_comment_count'], reported)
                self.assertEqual(result['coverage'], 'complete' if retrieved == reported else 'partial')
                for comment in thread['comments']:
                    self.assertIn('/' + comment['id'] + '/', comment['canonical_reddit_url'])
                    self.assertIsNotNone(comment['author'])
                    self.assertIsNotNone(comment['created_at'])
                if label == 'thread-flash':
                    self.assertEqual(thread['title'], 'Example model setup')
                    self.assertEqual(thread['upvote_ratio'], 0.5)
                    reply = next(c for c in thread['comments'] if c['id'] == 'reply1')
                    self.assertEqual(reply['parent_id'], 'comment0')
                    sentence = next(c['body_text'] for c in thread['comments'] if c['id'] == 'sentence1')
                    self.assertIn("use the example template and sampling parameters to reduce", sentence)

    def test_rss_sample_suggestions_are_filtered_and_comments_grouped(self):
        search = MOD.parse_rss((FIXTURES / 'sample-search-dsh.raw').read_text(encoding='utf-8'), 'https://www.reddit.com/search.rss')
        self.assertEqual(len(search['threads']), 22)
        self.assertTrue(all(t['id'] for t in search['threads']))
        result = MOD.parse_rss((FIXTURES / 'sample-thread-settings-rss.raw').read_text(encoding='utf-8'), 'https://www.reddit.com/r/LocalLLaMA/comments/post03/example/.rss')
        self.assertEqual(len(result['threads']), 1)
        thread = result['threads'][0]
        self.assertEqual(thread['retrieved_comment_count'], 22)
        self.assertEqual(result['coverage'], 'partial')
        self.assertEqual(thread['comments'][0]['id'], 'c0')
        self.assertNotIn('<p>', thread['body_text'])
        self.assertNotIn('submitted by', thread['body_text'])
        self.assertTrue(all(c['depth'] is None for c in thread['comments']))

    def test_text_order_code_indentation_and_tables(self):
        root = MOD.parse_html_document('<p>Use <a href="/">this link</a> before <strong>that</strong>.</p><pre><code>if x:\n    print("→")\n</code></pre><table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table>')
        text = root.text()
        self.assertIn('Use this link before that.', text)
        self.assertIn('if x:\n    print("→")\n', text)
        self.assertIn('A\tB\t', text)
        self.assertIn('1\t2', text)

    def test_windows_legacy_encoding_cli_and_stdin(self):
        env = dict(os.environ, PYTHONUTF8='0', PYTHONIOENCODING='cp1252')
        raw = (FIXTURES / 'sample-search-dsh.raw').read_bytes()
        completed = subprocess.run([sys.executable, str(SCRIPT), 'parse', 'rss', '--source-url', 'https://www.reddit.com/search.rss'], input=raw, capture_output=True, env=env)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        parsed = json.loads(completed.stdout.decode('utf-8'))
        self.assertEqual(len(parsed['threads']), 22)
        self.assertIn('→', completed.stdout.decode('utf-8'))

    def test_redlib_branding_without_thread_is_rejected(self):
        raw = '<html><head><meta name="description" content="View on Redlib"></head><body>Access denied</body></html>'
        with self.assertRaisesRegex(ValueError, 'parse_failure'):
            MOD.parse_redlib_thread(raw, 'http://127.0.0.1:18080/r/test/comments/abc123/post/')


if __name__ == "__main__":
    unittest.main()
