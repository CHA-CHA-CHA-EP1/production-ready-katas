package main

import (
	"fmt"
	"io"
	"os"
)

const maxSize = 1024 * 1024

func ReadConfig(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("ReadConfig: %w", err)
	}

	defer file.Close()

	fileInfo, err := file.Stat()
	if err != nil {
		return nil, fmt.Errorf("ReadConfig: %w", err)
	}

	if fileInfo.Size() > maxSize {
		return nil, fmt.Errorf("ReadConfig: file %s size %d exceeds %d byte limit", path, fileInfo.Size(), maxSize)
	}

	buf := make([]byte, fileInfo.Size())
	_, err = io.ReadFull(file, buf)
	if err != nil {
		return nil, fmt.Errorf("ReadConfig: %w", err)
	}

	return buf, nil
}

func main() {
	bytes, err := ReadConfig("2go.mod")
	if err != nil {
		fmt.Println(err.Error())
		os.Exit(1)
	}

	fmt.Println(string(bytes))
}
