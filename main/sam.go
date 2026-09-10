package main

import "fmt"

type Trace struct {
	ParentID int
	ID       int
}

func worker(t Trace) {
	fmt.Printf("Parent ID: %d, Current ID: %d\n", t.ParentID, t.ID)
}

func main() {
	parent := Trace{ParentID: 0, ID: 1}
	go worker(Trace{ParentID: parent.ID, ID: 2})
}
