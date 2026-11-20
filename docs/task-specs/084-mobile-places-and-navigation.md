# Task 084: Places and navigation in the mobile app

Status: Active
Design: [RelayBar for iPhone and iPad](../designs/relaybar-ios.md)
Depends on: Task 083

## Outcome

A folder a person cares about is one tap from launch on iPhone and already open on iPad, and no list appears twice on a screen.

First use on an iPad showed two faults. The app has no notion of chosen folders, so reaching a deep notes folder means walking down from the top each time. And each screen keeps its own lists: with nothing open, the iPad shows the phone's Home beside a sidebar that already holds the host, the services and a location field.

## Delivery Boundary

Included: `Apps/RelayBarMobile`, and the mobile parts of `Packages/AppComposition` if a shared view needs it.

Excluded: finding a file by name across a folder tree (Task 085), any change to the Mac apps, the transport, the web routes or what a plugin may do.

## Work

1. **Places.** Each host has an ordered list of places: Home, always first, then the folders and files the person has pinned. Pinning is the Favourites plugin, widened from files to folders and retitled to match; existing favourites carry over. With the plugin off, Home is the only place. A folder is pinned or unpinned from its page and from any folder row's menu; a file as today. Pinned entries can be reordered and removed where they are listed. The place last chosen for a host is remembered and is the current place.
2. **iPhone Home.** Sections in this order, each thing once: Continue reading; Places; Recent, at most five with the rest behind Show All; Services. Places replaces the Browse Files row and the Favourites section. Services is one list of pinned then open services, with one quiet row that opens the location field when there are none; the separate Web Services row goes. The host name opens Hosts and one button opens Settings; the menu that repeats Hosts goes.
3. **iPad sidebar.** Top to bottom: host and Settings; the location field; Places, with the current one marked; the file tree of the current place; Services, pinned then open, replacing the boxed count. Choosing a folder place roots the tree there. Choosing a pinned file opens it.
4. **iPad tree.** The tree is rooted at the current place and no longer follows the last document read. Expanded folders are remembered per host and place across launches. Opening a document inside the current place expands to it and marks it. A document elsewhere marks nothing, and the reader offers Show in Files, which makes that document's folder the tree's root without pinning it. A folder row's menu offers Open Folder, Pin and Show as Root. A folder with more than 200 entries shows the first 200 and a row that shows the rest.
5. **iPad with nothing open.** The page area shows Continue reading and Recent in a column of reading width, and nothing the sidebar already shows. The sidebar can be hidden and shown from the page's top bar whether one page or two are open, and the choice is remembered.
6. **Location field.** When opened from Home it offers the hints and Hosts only; from any other page it also offers Places, Recent and Services. Typing a path completes it against the folder being typed: matching entries are listed, folders first; choosing a folder extends the text and lists that folder; choosing a file opens it; Return opens what is typed. A folder result can be pinned from the list. Results come from a list of sources so Task 085 can add another.
7. **Folder page.** Under the title, the path is shown as segments from Home or the root, and each segment opens that folder. A pin control sits with the layout and sort controls. A filter field is shown at the top when the folder has more than fifteen entries, and filters as the person types. Folders come first in every order. The chosen order is remembered per host.
8. **Reader on iPhone.** The folder path above the title opens that folder.
9. **Wording.** Text that names the device says iPad on an iPad.
10. **Gallery.** The screen gallery covers the new Home, the iPad with nothing open, the iPad sidebar with two places and an expanded tree, the location field completing a path, and a long folder with its path and filter, in both appearances. The demo host gains a second place.
11. **Specs.** Update `docs/system-specs/modules/mobile-app.md` and the Main path and Plugins sections of the design page.

## Acceptance

- On iPhone, a pinned folder opens from Home in one tap, and Home shows no service, document or folder in two sections.
- On iPad, relaunching with a pinned folder as the current place shows its tree with the same folders expanded and the last document open, with no page that repeats the sidebar.
- Opening a document from Recent that lies outside the current place leaves the tree's root and expansion unchanged.
- Typing the start of a folder name after `~/` lists it, and choosing it lists its contents without Return.
- A favourite saved before this change appears in Places.
- With Favourites off for a host, that host shows only Home in Places and no pin controls.
- Unit tests cover the stored places and their migration, tree-state persistence and its limit, path completion, and the Home section order.
- `scripts/test.sh mobile` passes, the app builds for the iOS SDK with warnings as errors, and the gallery images are regenerated and reviewed.
