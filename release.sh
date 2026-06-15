#!/bin/bash
set -e

# Usage: ./release.sh 1.2.0
# Creates a version bump, commits it, tags it, and pushes it to trigger GitHub Actions release

if [ -z "$1" ]; then
  echo "Usage: $0 <version>"
  echo "Example: $0 1.2.0"
  exit 1
fi

VERSION="$1"
TAG="v$VERSION"

# Validate version format (semver: major.minor.patch)
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Error: Version must be in semver format (e.g., 1.2.0)"
  exit 1
fi

echo "🚀 Releasing NoNoise Mac v$VERSION"
echo ""

# Check if we're on main branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "main" ]; then
  echo "❌ Error: You must be on the 'main' branch to release"
  exit 1
fi

# Check if there are uncommitted changes
if ! git diff-index --quiet HEAD --; then
  echo "❌ Error: You have uncommitted changes. Please commit or stash them first."
  exit 1
fi

# Update version in Info.plist
PLIST_FILE="Resources/Info.plist"
if [ ! -f "$PLIST_FILE" ]; then
  echo "❌ Error: $PLIST_FILE not found"
  exit 1
fi

echo "📝 Updating version in $PLIST_FILE"
# Extract major.minor for CFBundleVersion
BUILD_NUMBER=$(echo "$VERSION" | cut -d. -f1-2 | tr '.' '')
sed -i '' "s/<string>.*<\/string>/<string>$VERSION<\/string>/g; t; b" "$PLIST_FILE" 2>/dev/null || true

# More reliable approach using plutil if available (macOS)
if command -v plutil &> /dev/null; then
  plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST_FILE"
  plutil -replace CFBundleVersion -string "${BUILD_NUMBER}" "$PLIST_FILE"
else
  # Fallback: manual sed
  sed -i '' "/<key>CFBundleShortVersionString<\/key>/,/<\/string>/ s/<string>.*<\/string>/<string>$VERSION<\/string>/" "$PLIST_FILE"
  sed -i '' "/<key>CFBundleVersion<\/key>/,/<\/string>/ s/<string>.*<\/string>/<string>${BUILD_NUMBER}<\/string>/" "$PLIST_FILE"
fi

echo "✅ Version updated to $VERSION"
echo ""

# Commit
echo "📦 Committing version bump"
git add "$PLIST_FILE"
git commit -m "chore(release): bump version to $VERSION"
echo "✅ Committed"
echo ""

# Create tag
echo "🏷️  Creating git tag $TAG"
git tag "$TAG"
echo "✅ Tag created"
echo ""

# Push
echo "🚀 Pushing to GitHub (this triggers the release workflow)"
git push origin main "$TAG"
echo "✅ Pushed!"
echo ""

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "✨ Release v$VERSION is now live!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "The GitHub Actions workflow is building binaries..."
echo "Watch progress: https://github.com/ivalsaraj/NoNoise-Mac/actions"
echo ""
echo "Release artifacts (app, CLI, driver) will be available in ~2-5 min at:"
echo "https://github.com/ivalsaraj/NoNoise-Mac/releases/tag/$TAG"
