genhtml: genhtml.c
	gcc genhtml.c -lm -o genhtml

parsehtml: parsehtml.c
	gcc hashtable.c hashtable_itr.c parsehtml.c -lcrypto -lm -o parsehtml
	
run: genhtml
	rm -rf docs
	mkdir docs
	./genhtml
