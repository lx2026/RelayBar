.PHONY: test test-relaybar test-frame test-shared relaybar frame
test:
	./scripts/test.sh
test-relaybar:
	./scripts/test.sh relaybar
test-frame:
	./scripts/test.sh frame
test-shared:
	./scripts/test.sh shared
relaybar:
	./scripts/build-app.sh
frame:
	./Apps/Frame/Scripts/build-app.sh
