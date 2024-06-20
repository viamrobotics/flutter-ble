.PHONY: lint lint-dart lint-ios lint-android format format-dart format-ios format-android test

lint-dart:
	dart analyze --no-fatal-warnings

lint-ios:
	swiftlint ios

lint-android:
	ktlint android

lint: lint-dart lint-ios lint-android

format-dart:
	dart fix --apply
	dart format --line-length=140 $$(find . -name "*.dart" -not -path "**.mocks.dart" -not -path "**/.dart_tool/*")

format-ios:
	swiftlint --format --fix ios

format-android:
	ktlint --format android

format: format-dart format-ios format-android

test:
	flutter test
