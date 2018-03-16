# cython: profile=True
# coding: utf8
from __future__ import unicode_literals, print_function

import re
import ujson
import random
import cytoolz
import itertools
import numpy
import tempfile
import shutil
from pathlib import Path
import msgpack

from . import _align 
from .syntax import nonproj
from .tokens import Doc
from . import util
from .util import minibatch, itershuffle


def tags_to_entities(tags):
    entities = []
    start = None
    for i, tag in enumerate(tags):
        if tag is None:
            continue
        if tag.startswith('O'):
            # TODO: We shouldn't be getting these malformed inputs. Fix this.
            if start is not None:
                start = None
            continue
        elif tag == '-':
            continue
        elif tag.startswith('I'):
            assert start is not None, tags[:i]
            continue
        if tag.startswith('U'):
            entities.append((tag[2:], i, i))
        elif tag.startswith('B'):
            start = i
        elif tag.startswith('L'):
            entities.append((tag[2:], start, i))
            start = None
        else:
            raise Exception(tag)
    return entities


def merge_sents(sents):
    m_deps = [[], [], [], [], [], []]
    m_brackets = []
    i = 0
    for (ids, words, tags, heads, labels, ner), brackets in sents:
        m_deps[0].extend(id_ + i for id_ in ids)
        m_deps[1].extend(words)
        m_deps[2].extend(tags)
        m_deps[3].extend(head + i for head in heads)
        m_deps[4].extend(labels)
        m_deps[5].extend(ner)
        m_brackets.extend((b['first'] + i, b['last'] + i, b['label'])
                          for b in brackets)
        i += len(ids)
    return [(m_deps, m_brackets)]


punct_re = re.compile(r'\W')
def align(cand_words, gold_words):
    if cand_words == gold_words:
        alignment = numpy.arange(len(cand_words))
        return 0, alignment, alignment, {}, {}
    cand_words = [w.replace(' ', '') for w in cand_words]
    gold_words = [w.replace(' ', '') for w in gold_words]
    cost, i2j, j2i, matrix = _align.align(cand_words, gold_words)
    i2j_multi, j2i_multi = _align.multi_align(i2j, j2i, [len(w) for w in cand_words],
                                [len(w) for w in gold_words])
    for i, j in list(i2j_multi.items()):
        if i2j_multi.get(i+1) != j and i2j_multi.get(i-1) != j:
            i2j[i] = j
            i2j_multi.pop(i)
    for j, i in list(j2i_multi.items()):
        if j2i_multi.get(j+1) != i and j2i_multi.get(j-1) != i:
            j2i[j] = i
            j2i_multi.pop(j)
    return cost, i2j, j2i, i2j_multi, j2i_multi


class GoldCorpus(object):
    """An annotated corpus, using the JSON file format. Manages
    annotations for tagging, dependency parsing and NER."""
    def __init__(self, train, dev, gold_preproc=True, limit=None):
        """Create a GoldCorpus.

        train_path (unicode or Path): File or directory of training data.
        dev_path (unicode or Path): File or directory of development data.
        RETURNS (GoldCorpus): The newly created object.
        """
        self.limit = limit
        if isinstance(train, str) or isinstance(train, Path):
            train = self.read_tuples(self.walk_corpus(train))
            dev = self.read_tuples(self.walk_corpus(dev))

        # Write temp directory with one doc per file, so we can shuffle
        # and stream
        self.tmp_dir = Path(tempfile.mkdtemp())
        self.write_msgpack(self.tmp_dir / 'train', train)
        self.write_msgpack(self.tmp_dir / 'dev', dev)

    def __del__(self):
        shutil.rmtree(self.tmp_dir)

    @staticmethod
    def write_msgpack(directory, doc_tuples):
        if not directory.exists():
            directory.mkdir()
        for i, doc_tuple in enumerate(doc_tuples):
            with open(directory / '{}.msg'.format(i), 'wb') as file_:
                msgpack.dump(doc_tuple, file_)

    @staticmethod
    def walk_corpus(path):
        path = util.ensure_path(path)
        if not path.is_dir():
            return [path]
        paths = [path]
        locs = []
        seen = set()
        for path in paths:
            if str(path) in seen:
                continue
            seen.add(str(path))
            if path.parts[-1].startswith('.'):
                continue
            elif path.is_dir():
                paths.extend(path.iterdir())
            elif path.parts[-1].endswith('.json'):
                locs.append(path)
        return locs

    @staticmethod
    def read_tuples(locs, limit=0):
        i = 0
        for loc in locs:
            loc = util.ensure_path(loc)
            if loc.parts[-1].endswith('json'):
                gold_tuples = read_json_file(loc)
            elif loc.parts[-1].endswith('msg'):
                with loc.open('rb') as file_:
                    gold_tuples = [msgpack.load(file_)]
            else:
                msg = "Cannot read from file: %s. Supported formats: .json, .msg"
                raise ValueError(msg % loc)
            for item in gold_tuples:
                yield item
                i += len(item[1])
                if limit and i >= limit:
                    break

    @property
    def dev_tuples(self):
        locs = (self.tmp_dir / 'dev').iterdir()
        yield from self.read_tuples(locs, limit=self.limit)
   
    @property
    def train_tuples(self):
        locs = (self.tmp_dir / 'train').iterdir()
        yield from self.read_tuples(locs, limit=self.limit)

    def count_train(self):
        n = 0
        i = 0
        for raw_text, paragraph_tuples in self.train_tuples:
            n += sum([len(s[0][1]) for s in paragraph_tuples])
            if self.limit and i >= self.limit:
                break
            i += len(paragraph_tuples)
        return n

    def train_docs(self, nlp, gold_preproc=False, max_length=None,
                    noise_level=0.0):
        locs = list((self.tmp_dir / 'train').iterdir())
        random.shuffle(locs)
        train_tuples = self.read_tuples(locs, limit=self.limit)
        gold_docs = self.iter_gold_docs(nlp, train_tuples, gold_preproc,
                                        max_length=max_length,
                                        noise_level=noise_level)
        yield from gold_docs

    def dev_docs(self, nlp, gold_preproc=False):
        gold_docs = self.iter_gold_docs(nlp, self.dev_tuples, gold_preproc)
        yield from gold_docs

    @classmethod
    def iter_gold_docs(cls, nlp, tuples, gold_preproc, max_length=None,
                       noise_level=0.0):
        for raw_text, paragraph_tuples in tuples:
            if gold_preproc:
                raw_text = None
            else:
                paragraph_tuples = merge_sents(paragraph_tuples)
            docs = cls._make_docs(nlp, raw_text, paragraph_tuples,
                                  gold_preproc, noise_level=noise_level)
            golds = cls._make_golds(docs, paragraph_tuples)
            for doc, gold in zip(docs, golds):
                if (not max_length) or len(doc) < max_length:
                    yield doc, gold

    @classmethod
    def _make_docs(cls, nlp, raw_text, paragraph_tuples, gold_preproc,
                   noise_level=0.0):
        if raw_text is not None:
            raw_text = add_noise(raw_text, noise_level)
            return [nlp.make_doc(raw_text)]
        else:
            return [Doc(nlp.vocab,
                        words=add_noise(sent_tuples[1], noise_level))
                    for (sent_tuples, brackets) in paragraph_tuples]

    @classmethod
    def _make_golds(cls, docs, paragraph_tuples):
        assert len(docs) == len(paragraph_tuples)
        if len(docs) == 1:
            return [GoldParse.from_annot_tuples(docs[0],
                                                paragraph_tuples[0][0])]
        else:
            return [GoldParse.from_annot_tuples(doc, sent_tuples)
                    for doc, (sent_tuples, brackets)
                    in zip(docs, paragraph_tuples)]


def add_noise(orig, noise_level):
    if random.random() >= noise_level:
        return orig
    elif type(orig) == list:
        corrupted = [_corrupt(word, noise_level) for word in orig]
        corrupted = [w for w in corrupted if w]
        return corrupted
    else:
        return ''.join(_corrupt(c, noise_level) for c in orig)


def _corrupt(c, noise_level):
    if random.random() >= noise_level:
        return c
    elif c == ' ':
        return '\n'
    elif c == '\n':
        return ' '
    elif c in ['.', "'", "!", "?"]:
        return ''
    else:
        return c.lower()


def read_json_file(loc, docs_filter=None, limit=None):
    loc = util.ensure_path(loc)
    if loc.is_dir():
        for filename in loc.iterdir():
            yield from read_json_file(loc / filename, limit=limit)
    else:
        with loc.open('r', encoding='utf8') as file_:
            docs = ujson.load(file_)
        if limit is not None:
            docs = docs[:limit]
        for doc in docs:
            if docs_filter is not None and not docs_filter(doc):
                continue
            paragraphs = []
            for paragraph in doc['paragraphs']:
                sents = []
                for sent in paragraph['sentences']:
                    words = []
                    ids = []
                    tags = []
                    heads = []
                    labels = []
                    ner = []
                    for i, token in enumerate(sent['tokens']):
                        words.append(token['orth'])
                        ids.append(i)
                        tags.append(token.get('tag', '-'))
                        heads.append(token.get('head', 0) + i)
                        labels.append(token.get('dep', ''))
                        # Ensure ROOT label is case-insensitive
                        if labels[-1].lower() == 'root':
                            labels[-1] = 'ROOT'
                        ner.append(token.get('ner', '-'))
                    sents.append([
                        [ids, words, tags, heads, labels, ner],
                        sent.get('brackets', [])])
                if sents:
                    yield [paragraph.get('raw', None), sents]


def iob_to_biluo(tags):
    out = []
    curr_label = None
    tags = list(tags)
    while tags:
        out.extend(_consume_os(tags))
        out.extend(_consume_ent(tags))
    return out


def _consume_os(tags):
    while tags and tags[0] == 'O':
        yield tags.pop(0)


def _consume_ent(tags):
    if not tags:
        return []
    target = tags.pop(0).replace('B', 'I')
    length = 1
    while tags and tags[0] == target:
        length += 1
        tags.pop(0)
    label = target[2:]
    if length == 1:
        return ['U-' + label]
    else:
        start = 'B-' + label
        end = 'L-' + label
        middle = ['I-%s' % label for _ in range(1, length - 1)]
        return [start] + middle + [end]


cdef class GoldParse:
    """Collection for training annotations."""
    @classmethod
    def from_annot_tuples(cls, doc, annot_tuples, make_projective=False):
        _, words, tags, heads, deps, entities = annot_tuples
        return cls(doc, words=words, tags=tags, heads=heads, deps=deps,
                   entities=entities, make_projective=make_projective)

    def __init__(self, doc, annot_tuples=None, words=None, tags=None,
                 heads=None, deps=None, entities=None, make_projective=False,
                 cats=None):
        """Create a GoldParse.

        doc (Doc): The document the annotations refer to.
        words (iterable): A sequence of unicode word strings.
        tags (iterable): A sequence of strings, representing tag annotations.
        heads (iterable): A sequence of integers, representing syntactic
            head offsets.
        deps (iterable): A sequence of strings, representing the syntactic
            relation types.
        entities (iterable): A sequence of named entity annotations, either as
            BILUO tag strings, or as `(start_char, end_char, label)` tuples,
            representing the entity positions.
        cats (dict): Labels for text classification. Each key in the dictionary
            may be a string or an int, or a `(start_char, end_char, label)`
            tuple, indicating that the label is applied to only part of the
            document (usually a sentence). Unlike entity annotations, label
            annotations can overlap, i.e. a single word can be covered by
            multiple labelled spans. The TextCategorizer component expects
            true examples of a label to have the value 1.0, and negative
            examples of a label to have the value 0.0. Labels not in the
            dictionary are treated as missing - the gradient for those labels
            will be zero.
        RETURNS (GoldParse): The newly constructed object.
        """
        if words is None:
            words = [token.text for token in doc]
        if tags is None:
            tags = [None for _ in doc]
        if heads is None:
            heads = [None for token in doc]
        if deps is None:
            deps = [None for _ in doc]
        if entities is None:
            entities = [None for _ in doc]
        elif len(entities) == 0:
            entities = ['O' for _ in doc]
        elif not isinstance(entities[0], basestring):
            # Assume we have entities specified by character offset.
            entities = biluo_tags_from_offsets(doc, entities)

        self.mem = Pool()
        self.loss = 0
        self.length = len(doc)

        # These are filled by the tagger/parser/entity recogniser
        self.c.tags = <int*>self.mem.alloc(len(doc), sizeof(int))
        self.c.heads = <int*>self.mem.alloc(len(doc), sizeof(int))
        self.c.labels = <attr_t*>self.mem.alloc(len(doc), sizeof(attr_t))
        self.c.has_dep = <int*>self.mem.alloc(len(doc), sizeof(int))
        self.c.sent_start = <int*>self.mem.alloc(len(doc), sizeof(int))
        self.c.ner = <Transition*>self.mem.alloc(len(doc), sizeof(Transition))

        self.cats = {} if cats is None else dict(cats)
        self.words = [None] * len(doc)
        self.tags = [None] * len(doc)
        self.heads = [None] * len(doc)
        self.labels = [None] * len(doc)
        self.ner = [None] * len(doc)

        # Do many-to-one alignment for misaligned tokens.
        # If we over-segment, we'll have one gold word that covers a sequence
        # of predicted words
        # If we under-segment, we'll have one predicted word that covers a
        # sequence of gold words.
        # If we "mis-segment", we'll have a sequence of predicted words covering
        # a sequence of gold words. That's many-to-many -- we don't do that.
        cost, i2j, j2i, i2j_multi, j2i_multi = align([t.orth_ for t in doc], words)

        self.cand_to_gold = [(j if j >= 0 else None) for j in i2j]
        self.gold_to_cand = [(i if i >= 0 else None) for i in j2i]

        annot_tuples = (range(len(words)), words, tags, heads, deps, entities)
        self.orig_annot = list(zip(*annot_tuples))

        for i, gold_i in enumerate(self.cand_to_gold):
            if doc[i].text.isspace():
                self.words[i] = doc[i].text
                self.tags[i] = '_SP'
                self.heads[i] = None
                self.labels[i] = None
                self.ner[i] = 'O'
            if gold_i is None:
                if i in i2j_multi:
                    self.words[i] = words[i2j_multi[i]]
                    self.tags[i] = tags[i2j_multi[i]]
                    # Set next word in multi-token span as head, until last
                    if i2j_multi[i] == i2j_multi.get(i+1):
                        self.heads[i] = i+1
                        self.labels[i] = 'subtok'
                    else:
                        self.heads[i] = self.gold_to_cand[heads[i2j_multi[i]]]
                        self.labels[i] = deps[i2j_multi[i]]
                    # TODO: Set NER!
            else:
                self.words[i] = words[gold_i]
                self.tags[i] = tags[gold_i]
                if heads[gold_i] is None:
                    self.heads[i] = None
                else:
                    self.heads[i] = self.gold_to_cand[heads[gold_i]]
                self.labels[i] = deps[gold_i]
                self.ner[i] = entities[gold_i]

        cycle = nonproj.contains_cycle(self.heads)
        if cycle is not None:
            raise Exception("Cycle found: %s" % cycle)

        if make_projective:
            proj_heads, _ = nonproj.projectivize(self.heads, self.labels)
            self.heads = proj_heads

    def __len__(self):
        """Get the number of gold-standard tokens.

        RETURNS (int): The number of gold-standard tokens.
        """
        return self.length

    @property
    def is_projective(self):
        """Whether the provided syntactic annotations form a projective
        dependency tree.
        """
        return not nonproj.is_nonproj_tree(self.heads)

    @property
    def sent_starts(self):
        return [self.c.sent_start[i] for i in range(self.length)]


def biluo_tags_from_offsets(doc, entities, missing='O'):
    """Encode labelled spans into per-token tags, using the
    Begin/In/Last/Unit/Out scheme (BILUO).

    doc (Doc): The document that the entity offsets refer to. The output tags
        will refer to the token boundaries within the document.
    entities (iterable): A sequence of `(start, end, label)` triples. `start`
        and `end` should be character-offset integers denoting the slice into
        the original string.
    RETURNS (list): A list of unicode strings, describing the tags. Each tag
        string will be of the form either "", "O" or "{action}-{label}", where
        action is one of "B", "I", "L", "U". The string "-" is used where the
        entity offsets don't align with the tokenization in the `Doc` object.
        The training algorithm will view these as missing values. "O" denotes a
        non-entity token. "B" denotes the beginning of a multi-token entity,
        "I" the inside of an entity of three or more tokens, and "L" the end
        of an entity of two or more tokens. "U" denotes a single-token entity.

    EXAMPLE:
        >>> text = 'I like London.'
        >>> entities = [(len('I like '), len('I like London'), 'LOC')]
        >>> doc = nlp.tokenizer(text)
        >>> tags = biluo_tags_from_offsets(doc, entities)
        >>> assert tags == ['O', 'O', 'U-LOC', 'O']
    """
    starts = {token.idx: token.i for token in doc}
    ends = {token.idx+len(token): token.i for token in doc}
    biluo = ['-' for _ in doc]
    # Handle entity cases
    for start_char, end_char, label in entities:
        start_token = starts.get(start_char)
        end_token = ends.get(end_char)
        # Only interested if the tokenization is correct
        if start_token is not None and end_token is not None:
            if start_token == end_token:
                biluo[start_token] = 'U-%s' % label
            else:
                biluo[start_token] = 'B-%s' % label
                for i in range(start_token+1, end_token):
                    biluo[i] = 'I-%s' % label
                biluo[end_token] = 'L-%s' % label
    # Now distinguish the O cases from ones where we miss the tokenization
    entity_chars = set()
    for start_char, end_char, label in entities:
        for i in range(start_char, end_char):
            entity_chars.add(i)
    for token in doc:
        for i in range(token.idx, token.idx+len(token)):
            if i in entity_chars:
                break
        else:
            biluo[token.i] = missing
    return biluo


def offsets_from_biluo_tags(doc, tags):
    """Encode per-token tags following the BILUO scheme into entity offsets.

    doc (Doc): The document that the BILUO tags refer to.
    entities (iterable): A sequence of BILUO tags with each tag describing one
        token. Each tags string will be of the form of either "", "O" or
        "{action}-{label}", where action is one of "B", "I", "L", "U".
    RETURNS (list): A sequence of `(start, end, label)` triples. `start` and
        `end` will be character-offset integers denoting the slice into the
        original string.
    """
    token_offsets = tags_to_entities(tags)
    offsets = []
    for label, start_idx, end_idx in token_offsets:
        span = doc[start_idx : end_idx + 1]
        offsets.append((span.start_char, span.end_char, label))
    return offsets


def is_punct_label(label):
    return label == 'P' or label.lower() == 'punct'
