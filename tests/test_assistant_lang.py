from assistant.lang import BILINGUAL_INSTRUCTION, split_bilingual


def test_split_bilingual_basic():
    zh, en = split_bilingual("===ZH===\n# 日报\n涨了\n===EN===\n# Brief\nUp day")
    assert zh == "# 日报\n涨了"
    assert en == "# Brief\nUp day"


def test_split_bilingual_tolerates_padding_and_case():
    zh, en = split_bilingual("好的，如下：\n === zh === \n中文\n ==EN== \nEnglish")
    assert zh == "中文"
    assert en == "English"


def test_split_bilingual_without_markers_is_all_chinese():
    zh, en = split_bilingual("# 日报\n没有标记的旧式输出")
    assert zh == "# 日报\n没有标记的旧式输出"
    assert en == ""


def test_split_bilingual_empty():
    assert split_bilingual("") == ("", "")


def test_split_bilingual_repeated_blocks_join():
    zh, en = split_bilingual("===ZH===\n一\n===EN===\none\n===ZH===\n二")
    assert zh == "一\n\n二"
    assert en == "one"


def test_instruction_mentions_both_markers():
    assert "===ZH===" in BILINGUAL_INSTRUCTION
    assert "===EN===" in BILINGUAL_INSTRUCTION
