"""Extract common substrings from sentence aligned corpora."""

from __future__ import print_function
import sys
import itertools

# Cython imports
cimport cython
from libc.stdlib cimport abort, malloc, free
from libc.stdint cimport uint8_t, uint32_t
from libc.string cimport memcmp
from cython.parallel cimport parallel, prange
from corpus cimport Text, Token, Sequence, SeqIdx, Comparator
include "constants.pxi"


cdef struct Match:
	SeqIdx start  # source match start idx
	SeqIdx end  # source match end idx


@cython.freelist(1000)
cdef class SubString:
	"""A contiguous substring of a Sequence."""
	cdef Sequence *seq
	cdef SeqIdx start, end

	def __richcmp__(self, other, int op):
		cdef int cmp = 0
		cdef SubString me, ob
		if (not isinstance(self, SubString) or not isinstance(other, SubString)
				or op < 2 or op > 3):  # no <, >, etc.
			return NotImplemented

		me = self
		ob = other
		if me.seq is ob.seq and me.start == ob.start and me.end == ob.end:
			return op == 2
		elif (me.end - me.start) == (ob.end - ob.start):
			cmp = memcmp(
					<char *>&(me.seq.tokens[me.start]),
					<char *>&(ob.seq.tokens[ob.start]),
					(me.end - me.start) * sizeof(Token))
			return (op == 2) == (cmp == 0)

	def __hash__(self):
		cdef long n, _hash = 5381
		for n in range(self.start * sizeof(Token), self.end * sizeof(Token)):
			_hash = (_hash << 5) + _hash + (<uint8_t *>self.seq.tokens)[n]
		return _hash

	def __nonzero__(self):
		return self.start != self.end

	def __len__(self):
		return self.end - self.start

	def __repr__(self):
		cdef int n
		return '%s(<%d:%d==%r>)' % (
				self.__class__.__name__, self.start, self.end,
				[self.seq.tokens[n] for n in range(self.start, self.end)])


cdef inline SubString new_SubString(Sequence *seq, SeqIdx start, SeqIdx end):
	cdef SubString substring = SubString.__new__(SubString)
	substring.seq = seq
	substring.start = start
	substring.end = end
	return substring


cdef class ParallelComparator(Comparator):
	"""Load a file after which its parallel substrings with respect
	to other files can be extracted."""
	cdef Text text2
	def getsequences(self, filename, int minmatchsize=1, bint debug=False):
		"""Get common substrings for two sentence aligned files."""
		cdef:
			SeqIdx *chart1
			SeqIdx *chart2
			Sequence *text1seqs  # source = text1
			Sequence *text2seqs  # target = text2
			Sequence *seq1s
			Sequence *seq1t
			Match *matches1
			Match *matches2
			SubString sourcematch, targetmatch
			long n, m, s, x, y
			long text1length, text2length
			int text1maxlen, text2maxlen
			set indexset
			dict table = {}  # dict of dict of sets
		self.text2 = self.readother(filename, storetokens=True)
		if self.text1.length != self.text2.length:
			raise ValueError('Source and target files have different '
					'number of lines: %d vs %d' % (
					self.text1.length, self.text2.length))
		print('%d sentences; %d token types.\n'
				'text1 max sent length: %d;\n'
				'text2 max sent length: %d.' % (
				self.text1.length, len(self.mapping),
				self.text1.maxlen, self.text2.maxlen), file=sys.stderr)
		text1length = self.text1.length
		text2length = self.text2.length
		text1maxlen = self.text1.maxlen
		text2maxlen = self.text2.maxlen
		text1seqs = self.text1.seqs
		text2seqs = self.text2.seqs


		for n in prange(text1length - 1, nogil=True, schedule='dynamic'):
			# allocate temporary datastructures
			chart1 = <SeqIdx *>malloc(text1maxlen * 3 * sizeof(SeqIdx))
			chart2 = <SeqIdx *>malloc(text2maxlen * 3 * sizeof(SeqIdx))
			if chart1 is NULL or chart2 is NULL:
				abort()
			matches1 = <Match *>malloc(text1maxlen * text1length
					* sizeof(Match))
			matches2 = <Match *>malloc(text2maxlen * text2length
					* sizeof(Match))
			if matches1 is NULL or matches2 is NULL:
				abort()
			seq1s = &(text1seqs[n])
			seq1t = &(text2seqs[n])

			getsequencesfor(n, text1length,
					chart1, chart2, text1seqs, text2seqs,
					minmatchsize, matches1, matches2)

			with gil:
				print('%d.' % n, file=sys.stderr)
				if debug:
					print(' '.join(['%d:%d:%s' % (s, seq1s.tokens[s], a)
							for s, a in enumerate(self.seqtostr(seq1s))]),
							file=sys.stderr)
					print(' '.join(['%d:%d' % (s, chart1[s])
								for s in range(seq1s.length)]),
								file=sys.stderr)

				# For each sentence m,
				for m in range(n + 1, self.text1.length):
					# and each longest substring in source text sentence m,
					for x in range(m * seq1s.length, (m + 1) * seq1s.length):
						if matches1[x].start == matches1[x].end:
							continue
						sourcematch = new_SubString(
								&(self.text1.seqs[n]),
								matches1[x].start, matches1[x].end)
						# Add the longest parallel substrs in same target sent.
						for y in range(m * seq1t.length,
								(m + 1) * seq1t.length):
							if matches2[y].start == matches2[y].end:
								continue
							targetmatch = new_SubString(
									&(self.text2.seqs[n]),
									matches2[y].start, matches2[y].end)
							if sourcematch == targetmatch:
								break  # FIXME: prune this string globally?
							if debug:
								print(sourcematch, targetmatch,
										file=sys.stderr)
							if sourcematch not in table:
								table[sourcematch] = {}
							if targetmatch in table[sourcematch]:
								indexset = table[sourcematch][targetmatch]
								indexset.add(n)
								indexset.add(m)
							else:
								table[sourcematch][targetmatch] = {n, m}
			# clean up
			free(chart1)
			free(chart2)
			free(matches1)
			free(matches2)

		return table

	cdef subtostr(self, SubString substring):
		"""Turn the array representation of a substring into a space separated
		string tokens."""
		cdef int n
		return ' '.join([
				self.revmapping[substring.seq.tokens[n]]
				for n in range(substring.start, substring.end)])

	def dumptable(self, table, out):
		for length, srcmatches in itertools.groupby(
				sorted(table, key=lambda x: len(x)),
				key=lambda x: len(x)):
			out.write('%d:\n' % length)
			for srcmatch in srcmatches:
				out.write('\t%s\n' % self.subtostr(srcmatch))
				for targetmatch, idx in table[srcmatch].iteritems():
					out.write('\t\t%s\t{%s}\n' % (
							self.subtostr(targetmatch),
							','.join([str(a) for a in idx])))


cdef void getsequencesfor(int n, int length,
			SeqIdx *chart1, SeqIdx *chart2,
			Sequence *text1seqs, Sequence *text2seqs,
			int minmatchsize, Match *matches1, Match *matches2) nogil:
	"""Compare sentence n against all sentences starting with n + 1."""
	cdef int m, s, t
	cdef Sequence *seq1s
	cdef Sequence *seq2s
	cdef Sequence *seq1t
	cdef Sequence *seq2t
	seq1s = &(text1seqs[n])
	seq1t = &(text2seqs[n])
	for m in range(n + 1, length):
		seq2s = &(text1seqs[m])
		longest_common_substrings(chart1, seq1s, seq2s)
		for s in range(seq1s.length):
			if (minmatchsize <= chart1[s] <= s
					and (s + 1 == seq1s.length
						or chart1[s + 1] != chart1[s] + 1)):
				matches1[m * seq1s.length + s].start = s - chart1[s] + 1
				matches1[m * seq1s.length + s].end = s + 1
			else:
				matches1[m * seq1s.length + s].start = 0
				matches1[m * seq1s.length + s].end = 0

		seq2t = &(text2seqs[m])
		longest_common_substrings(chart2, seq1t, seq2t)
		for t in range(seq1t.length):
			if (minmatchsize <= chart2[t] <= t
					and (t + 1 == seq1t.length
						or chart2[t + 1] != chart2[t] + 1)):
				matches2[m * seq1t.length + t].start = t - chart2[t] + 1
				matches2[m * seq1t.length + t].end = t + 1
			else:
				matches2[m * seq1t.length + t].start = 0
				matches2[m * seq1t.length + t].end = 0


cdef void longest_common_substrings(SeqIdx *chart,
		Sequence *seq1, Sequence *seq2) nogil:
	"""Return a set of ``SubString`` objects with the longest common substring
	at each position of ``seq1``."""
	cdef int n, m
	# longest[n] == length of common substring starting from n
	cdef SeqIdx *longest = chart
	# temp: current[m] is number of matches up to m and n
	cdef SeqIdx *current = &(chart[seq1.length])
	# temp: prev[m - 1] is number of matches up to m - 1 and n - 1
	cdef SeqIdx *prev = &(chart[seq1.length + seq2.length])

	n = 0
	longest[n] = 0
	for m in range(seq2.length):
		if seq1.tokens[n] == seq2.tokens[m]:
			prev[m] = longest[n] = 1
		else:
			prev[m] = 0

	for n in range(1, seq1.length):
		current[0] = longest[n] = seq1.tokens[n] == seq2.tokens[0]

		for m in range(1, seq2.length):
			if seq1.tokens[n] == seq2.tokens[m]:
				current[m] = prev[m - 1] + 1
				if current[m] > longest[n]:
					longest[n] = current[m]
			else:
				current[m] = 0

		current, prev = prev, current
