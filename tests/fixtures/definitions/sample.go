package tracker

import "strings"

type Tracker struct {
	root string
}

type Fetcher interface {
	Fetch(ref string) (string, error)
}

func New(root string) *Tracker {
	return &Tracker{root: root}
}

func (t *Tracker) Fetch(ref string) (string, error) {
	return strings.Join([]string{t.root, ref}, "/"), nil
}
