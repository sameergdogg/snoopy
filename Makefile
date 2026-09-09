.PHONY: gen build test hook run clean
gen: ; xcodegen generate
hook: ; ./Scripts/build-hook.sh
test: ; swift test --package-path Packages/SnoopyCore
build: gen ; xcodebuild -project Snoopy.xcodeproj -scheme Snoopy -configuration Debug build
run: build ; open $$(xcodebuild -project Snoopy.xcodeproj -scheme Snoopy -configuration Debug -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$$2} / FULL_PRODUCT_NAME /{n=$$2} END{print d"/"n}')
clean: ; rm -rf build Snoopy.xcodeproj DerivedData
