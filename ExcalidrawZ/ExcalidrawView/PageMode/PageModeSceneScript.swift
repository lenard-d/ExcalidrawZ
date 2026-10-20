import Foundation

/// Runs each command against the live scene. No native scene copy is written back.
enum PageModeSceneScript {
    static let body = #"""
    const helper = window.excalidrawZHelper;
    const api = helper?._api;
    if (!api || helper.currentFileId !== expectedFileID) {
        throw new Error("documentChanged");
    }
    const command = JSON.parse(commandJSON);
    const all = api.getSceneElementsIncludingDeleted();
    const live = all.filter(element => !element.isDeleted);
    const metadata = frame => frame.customData?.excalidrawZPage;
    const pages = live.filter(element => element.type === "frame" && metadata(element)?.version === 1);
    const sceneOrder = new Map(pages.map((page, index) => [page.id, index]));
    const order = frame => Number.isFinite(metadata(frame).order) ? metadata(frame).order : sceneOrder.get(frame.id);
    pages.sort((left, right) => {
        const difference = order(left) - order(right);
        return Number.isNaN(difference) || difference === 0
            ? sceneOrder.get(left.id) - sceneOrder.get(right.id) : difference;
    });
    const describe = page => ({
        id: page.id,
        title: typeof page.name === "string" ? page.name : "",
        width: page.width,
        height: page.height,
        locked: page.locked === true,
        layout: ["blank", "grid", "ruled"].includes(metadata(page)?.layout) ? metadata(page).layout : "blank",
        x: page.x,
        y: page.y,
    });
    const state = openedPageID => JSON.stringify({ pages: pages.map(describe), openedPageID });
    const getPage = () => {
        const page = pages.find(page => page.id === command.pageID);
        if (!page) throw new Error("pageMissing");
        return page;
    };
    const changesScene = ["add", "rename", "move", "remove", "setLayout"].includes(command.action);
    if (changesScene && api.getAppState().viewModeEnabled) {
        throw new Error("viewMode");
    }
    const assertEditable = page => {
        if (page.locked) throw new Error("pageLocked");
    };
    const pageData = (page, index) => ({
        ...page.customData,
        excalidrawZPage: { ...metadata(page), version: 1, order: index },
    });
    const capture = { captureUpdate: "IMMEDIATELY" };
    const cameraOptions = { animate: false, canvasOffsets: { top: 40, right: 40, bottom: 40, left: 40 } };
    const checkedLayout = value => {
        if (!["blank", "grid", "ruled"].includes(value)) throw new Error("invalidLayout");
        return value;
    };
    const isGuide = (element, page) => element.type === "line" && element.frameId === page.id &&
        element.locked === true && !element.boundElements?.length &&
        element.customData?.excalidrawZPageGuide?.version === 1;
    // Standard line children keep the paper visible in other Excalidraw apps and exports.
    const makeGuides = (page, layout) => {
        if (layout === "blank") return [];
        const { x, y, width, height } = page;
        if (![x, y, width, height].every(Number.isFinite) || width <= 0 || height <= 0 || width > 20000 || height > 20000) {
            throw new Error("invalidSize");
        }
        // At most 99 lines in either direction, including resized/imported pages.
        const spacing = 20 * Math.max(1, Math.ceil(Math.max(width, height) / 2000));
        const skeletons = [];
        const line = (x, y, width, height) => ({
            type: "line", x, y, width, height, points: [[0, 0], [width, height]],
            strokeColor: "#b8c5d6", strokeWidth: 0.5, roughness: 0,
            startArrowhead: null, endArrowhead: null,
        });
        for (let offset = spacing; offset < height; offset += spacing) skeletons.push(line(x, y + offset, width, 0));
        if (layout === "grid") {
            for (let offset = spacing; offset < width; offset += spacing) skeletons.push(line(x + offset, y, 0, height));
        }
        const guides = helper.createElements(skeletons);
        if (guides.length !== skeletons.length || guides.some(element => element.type !== "line")) throw new Error("failedAction");
        return guides.map(element => ({ ...element, frameId: page.id, locked: true,
            customData: { ...element.customData, excalidrawZPageGuide: { version: 1, pageID: page.id } } }));
    };
    // Keep the live objects intact until updateScene captures the undo change.
    const updatePages = patches => {
        const updates = new Map(patches.map(patch => [patch.id, patch.updates]));
        const elements = all.map(element => {
            if (!updates.has(element.id)) return element;
            const copy = { ...element };
            api.mutateElement(copy, updates.get(element.id), false);
            return copy;
        });
        api.updateScene({ elements, ...capture });
    };

    switch (command.action) {
        case "list":
            return state(null);
        case "add": {
            const reference = command.pageID == null ? null : getPage();
            if (reference) assertEditable(reference);
            const { width, height } = reference ?? command;
            const minimum = reference ? 1 : 100;
            const maximum = reference ? 20000 : 2000;
            if (![width, height].every(value => Number.isFinite(value) && value >= minimum && value <= maximum)) {
                throw new Error("invalidSize");
            }
            // A circumscribed rectangle also clears rotated existing elements.
            let bottom = -80;
            for (const element of live) {
                const values = [element.x, element.y, element.width, element.height];
                if (!values.every(Number.isFinite)) throw new Error("invalidBounds");
                const radius = Math.hypot(element.width, element.height) / 2;
                bottom = Math.max(bottom, element.y + element.height / 2 + radius);
            }
            let x = pages.length ? pages[pages.length - 1].x : 0;
            let y = bottom + 80;
            if (reference) {
                if (command.placement !== "below" && command.placement !== "right") throw new Error("failedAction");
                x = reference.x + (command.placement === "right" ? reference.width + 80 : 0);
                y = reference.y + (command.placement === "below" ? reference.height + 80 : 0);
                for (const element of live) {
                    const angle = Number.isFinite(element.angle) ? element.angle : 0;
                    const halfWidth = (Math.abs(element.width * Math.cos(angle)) + Math.abs(element.height * Math.sin(angle))) / 2;
                    const halfHeight = (Math.abs(element.width * Math.sin(angle)) + Math.abs(element.height * Math.cos(angle))) / 2;
                    const cx = element.x + element.width / 2;
                    const cy = element.y + element.height / 2;
                    if (cx + halfWidth > x && cx - halfWidth < x + width && cy + halfHeight > y && cy - halfHeight < y + height) {
                        throw new Error("spaceOccupied");
                    }
                }
            }
            if (![x, y].every(value => Number.isFinite(value) && Math.abs(value) <= 1e8)) throw new Error("noSpace");
            const created = helper.createElements([{ type: "frame", x, y, width, height, name: command.title || "", children: [] }]);
            if (created.length !== 1 || created[0].type !== "frame") throw new Error("failedAction");
            const frame = created[0];
            const highestOrder = pages.reduce((highest, page) => Math.max(highest, Number.isFinite(order(page)) ? order(page) : 0), -1);
            const layout = checkedLayout(reference ? describe(reference).layout : command.layout ?? "blank");
            frame.customData = { ...frame.customData, excalidrawZPage: { version: 1, order: highestOrder + 1, layout } };
            helper.addElements([...makeGuides(frame, layout), frame], capture);
            pages.push(frame);
            return state(frame.id);
        }
        case "setLayout": {
            const page = getPage();
            assertEditable(page);
            const layout = checkedLayout(command.layout);
            const guides = makeGuides(page, layout);
            const copy = { ...page };
            api.mutateElement(copy, { customData: { ...page.customData,
                excalidrawZPage: { ...metadata(page), layout } } }, false);
            const elements = all.map(element => {
                if (element.id === page.id) return copy;
                if (!element.isDeleted && isGuide(element, page)) {
                    const deleted = { ...element };
                    api.mutateElement(deleted, { isDeleted: true }, false);
                    return deleted;
                }
                return element;
            });
            // Place guides behind this frame's ink without reordering any existing content.
            const firstChild = elements.findIndex(element => element.id === page.id || element.frameId === page.id);
            elements.splice(firstChild, 0, ...guides);
            api.updateScene({ elements, ...capture });
            return JSON.stringify({ pages: pages.map(item => describe(item.id === page.id ? copy : item)), openedPageID: null });
        }
        case "rename": {
            const page = getPage();
            assertEditable(page);
            const title = typeof command.title === "string" ? command.title.trim() : "";
            if (!title || title.length > 120) throw new Error("invalidTitle");
            updatePages([{ id: page.id, updates: { name: title } }]);
            return JSON.stringify({ pages: pages.map(item => describe(item.id === page.id ? { ...item, name: title } : item)), openedPageID: null });
        }
        case "move": {
            const page = getPage();
            const index = pages.indexOf(page);
            if (command.offset !== -1 && command.offset !== 1) throw new Error("invalidMove");
            const target = index + command.offset;
            if (target < 0 || target >= pages.length) return state(null);
            pages.forEach(assertEditable);
            pages.splice(index, 1);
            pages.splice(target, 0, page);
            updatePages(pages.map((item, index) => ({ id: item.id, updates: { customData: pageData(item, index) } })));
            return state(null);
        }
        case "remove": {
            const page = getPage();
            assertEditable(page);
            const children = all.filter(element => element.frameId === page.id);
            updatePages([
                { id: page.id, updates: { isDeleted: true } },
                ...children.map(element => ({ id: element.id, updates: isGuide(element, page)
                    ? { isDeleted: true, frameId: null } : { frameId: null } })),
            ]);
            pages.splice(pages.indexOf(page), 1);
            return state(null);
        }
        case "open": {
            const page = getPage();
            helper.zoomToFitElements([page.id], cameraOptions);
            return state(page.id);
        }
        case "canvas":
            helper.zoomToFit(cameraOptions);
            return state(null);
        case "exportScene":
            return JSON.stringify({
                pages: pages.map(describe),
                scene: { elements: live, files: api.getFiles(), appState: { viewBackgroundColor: api.getAppState().viewBackgroundColor } },
            });
        default:
            throw new Error("failedAction");
    }
    """#
}
