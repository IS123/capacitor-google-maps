import { WebPlugin } from '@capacitor/core';
import { MarkerClusterer, SuperClusterAlgorithm } from '@googlemaps/markerclusterer';
import { MapType, LatLngBounds } from './definitions';
export class CapacitorGoogleMapsWeb extends WebPlugin {
    constructor() {
        super(...arguments);
        this.gMapsRef = undefined;
        this.AdvancedMarkerElement = undefined;
        this.PinElement = undefined;
        this.maps = {};
        this.currMarkerId = 0;
        this.currPolygonId = 0;
        this.currCircleId = 0;
        this.currPolylineId = 0;
        this.currMapId = 0;
        this.onClusterClickHandler = (_, cluster, map) => {
            var _a;
            const mapId = this.getIdFromMap(map);
            const items = [];
            if (cluster.markers != undefined && this.AdvancedMarkerElement) {
                for (const marker of cluster.markers) {
                    if (marker instanceof this.AdvancedMarkerElement) {
                        const markerId = this.getIdFromMarker(mapId, marker);
                        const position = marker.position;
                        items.push({
                            markerId: markerId,
                            latitude: position.lat,
                            longitude: position.lng,
                            title: (_a = marker.title) !== null && _a !== void 0 ? _a : '',
                            snippet: '',
                        });
                    }
                }
            }
            this.notifyListeners('onClusterClick', {
                mapId: mapId,
                latitude: cluster.position.lat,
                longitude: cluster.position.lng,
                size: cluster.count,
                items: items,
            });
        };
    }
    getIdFromMap(map) {
        for (const id in this.maps) {
            if (this.maps[id].map == map) {
                return id;
            }
        }
        return '';
    }
    getIdFromMarker(mapId, marker) {
        for (const id in this.maps[mapId].markers) {
            if (this.maps[mapId].markers[id] == marker) {
                return id;
            }
        }
        return '';
    }
    async importGoogleLib(apiKey, region, language) {
        if (this.gMapsRef === undefined) {
            const lib = await import('@googlemaps/js-api-loader');
            const loader = new lib.Loader({
                apiKey: apiKey !== null && apiKey !== void 0 ? apiKey : '',
                version: 'weekly',
                libraries: ['places'],
                language,
                region,
            });
            const google = await loader.load();
            this.gMapsRef = google.maps;
            // Import marker library once
            const { AdvancedMarkerElement, PinElement } = (await google.maps.importLibrary('marker'));
            this.AdvancedMarkerElement = AdvancedMarkerElement;
            this.PinElement = PinElement;
            console.log('Loaded google maps API');
        }
    }
    async enableTouch(_args) {
        this.maps[_args.id].map.setOptions({ gestureHandling: 'auto' });
    }
    async disableTouch(_args) {
        this.maps[_args.id].map.setOptions({ gestureHandling: 'none' });
    }
    async setCamera(_args) {
        // Animation not supported yet...
        this.maps[_args.id].map.moveCamera({
            center: _args.config.coordinate,
            heading: _args.config.bearing,
            tilt: _args.config.angle,
            zoom: _args.config.zoom,
        });
    }
    async getMapType(_args) {
        let type = this.maps[_args.id].map.getMapTypeId();
        if (type !== undefined) {
            if (type === 'roadmap') {
                type = MapType.Normal;
            }
            return { type: `${type.charAt(0).toUpperCase()}${type.slice(1)}` };
        }
        throw new Error('Map type is undefined');
    }
    async setMapType(_args) {
        let mapType = _args.mapType.toLowerCase();
        if (_args.mapType === MapType.Normal) {
            mapType = 'roadmap';
        }
        this.maps[_args.id].map.setMapTypeId(mapType);
    }
    async enableIndoorMaps() {
        throw new Error('Method not supported on web.');
    }
    async enableTrafficLayer(_args) {
        var _a;
        const trafficLayer = (_a = this.maps[_args.id].trafficLayer) !== null && _a !== void 0 ? _a : new google.maps.TrafficLayer();
        if (_args.enabled) {
            trafficLayer.setMap(this.maps[_args.id].map);
            this.maps[_args.id].trafficLayer = trafficLayer;
        }
        else if (this.maps[_args.id].trafficLayer) {
            trafficLayer.setMap(null);
            this.maps[_args.id].trafficLayer = undefined;
        }
    }
    async enableAccessibilityElements() {
        throw new Error('Method not supported on web.');
    }
    dispatchMapEvent() {
        throw new Error('Method not supported on web.');
    }
    async enableCurrentLocation(_args) {
        if (_args.enabled) {
            if (navigator.geolocation) {
                navigator.geolocation.getCurrentPosition((position) => {
                    const pos = {
                        lat: position.coords.latitude,
                        lng: position.coords.longitude,
                    };
                    this.maps[_args.id].map.setCenter(pos);
                    this.notifyListeners('onMyLocationButtonClick', {});
                    this.notifyListeners('onMyLocationClick', {});
                }, () => {
                    throw new Error('Geolocation not supported on web browser.');
                });
            }
            else {
                throw new Error('Geolocation not supported on web browser.');
            }
        }
    }
    async setPadding(_args) {
        const bounds = this.maps[_args.id].map.getBounds();
        if (bounds !== undefined) {
            this.maps[_args.id].map.fitBounds(bounds, _args.padding);
        }
    }
    async getMapBounds(_args) {
        const bounds = this.maps[_args.id].map.getBounds();
        if (!bounds) {
            throw new Error('Google Map Bounds could not be found.');
        }
        return new LatLngBounds({
            southwest: {
                lat: bounds.getSouthWest().lat(),
                lng: bounds.getSouthWest().lng(),
            },
            center: {
                lat: bounds.getCenter().lat(),
                lng: bounds.getCenter().lng(),
            },
            northeast: {
                lat: bounds.getNorthEast().lat(),
                lng: bounds.getNorthEast().lng(),
            },
        });
    }
    async fitBounds(_args) {
        const map = this.maps[_args.id].map;
        const bounds = this.getLatLngBounds(_args.bounds);
        map.fitBounds(bounds, _args.padding);
    }
    async addMarkers(_args) {
        const markerIds = [];
        const map = this.maps[_args.id];
        const currentMids = [];
        for (const markerArgs of _args.markers) {
            if (map.mIds[markerArgs.mId]) {
                const markerId = map.mIds[markerArgs.mId];
                currentMids.push(markerArgs.mId);
                this.updateMarker({
                    id: _args.id,
                    markerId: markerId,
                    marker: markerArgs
                });
                continue;
            }
            const advancedMarker = this.buildMarkerOpts(markerArgs, map.map);
            const id = '' + this.currMarkerId;
            map.markers[id] = advancedMarker;
            map.mIds[markerArgs.mId] = id;
            currentMids.push(markerArgs.mId);
            await this.setMarkerListeners(_args.id, id, markerArgs.mId, advancedMarker);
            markerIds.push(id);
            this.currMarkerId++;
        }
        const markersToRemove = Object.keys(map.mIds).filter(id => !currentMids.includes(id));
        this.removeMarkersBymId({
            id: _args.id,
            mIds: markersToRemove
        });
        return { ids: markerIds };
    }
    async addMarker(_args) {
        // clearAllMarkers = undefined by default, if you need to leave all markers you need to pass clearAllMarkers: false
        if (_args.clearAllMarkers || typeof _args.clearAllMarkers === 'undefined') {
            this.removeAllMarkers(_args.id);
        }
        const advancedMarker = this.buildMarkerOpts(_args.marker, this.maps[_args.id].map);
        const id = '' + this.currMarkerId;
        this.maps[_args.id].mIds[_args.marker.mId] = id;
        this.maps[_args.id].markers[id] = advancedMarker;
        await this.setMarkerListeners(_args.id, id, _args.marker.mId, advancedMarker);
        this.currMarkerId++;
        return { id: id };
    }
    async updateMarker(args) {
        await this.removeMarker({
            id: args.id,
            markerId: args.markerId
        });
        return (await this.addMarker({
            id: args.id,
            marker: args.marker,
            clearAllMarkers: false
        }));
    }
    async updateMarkerIcon(args) {
        var _a, _b;
        const id = this.maps[args.id].mIds[args.mId];
        const marker = this.maps[args.id].markers[id];
        if (marker) {
            // Clone the existing size/anchor/origin from the current icon if needed
            const iconUrl = args.iconUrl;
            const existingIcon = marker.content;
            const img = document.createElement('img');
            img.src = iconUrl;
            img.style.width = (_a = existingIcon === null || existingIcon === void 0 ? void 0 : existingIcon.style.width) !== null && _a !== void 0 ? _a : '32px';
            img.style.height = (_b = existingIcon === null || existingIcon === void 0 ? void 0 : existingIcon.style.height) !== null && _b !== void 0 ? _b : '32px';
            // Replace content
            marker.content = img;
        }
    }
    async removeMarkers(_args) {
        const map = this.maps[_args.id];
        for (const id of _args.markerIds) {
            if (map.markers[id]) {
                map.markers[id].map = null;
                delete map.markers[id];
                const mId = Object.values(map.mIds).find((markerId) => markerId === id);
                if (mId) {
                    delete map.mIds[mId];
                }
            }
        }
    }
    async removeMarker(_args) {
        const map = this.maps[_args.id];
        if (map.markers[_args.markerId]) {
            map.markers[_args.markerId].map = null;
            const mId = Object.values(map.mIds).find((markerId) => markerId === _args.markerId);
            delete map.markers[_args.markerId];
            if (mId) {
                delete map.mIds[mId];
            }
        }
    }
    async removeMarkerBymId(args) {
        const map = this.maps[args.id];
        const id = map.mIds[args.mId];
        map.markers[id] && (map.markers[id].map = null);
        delete map.markers[id];
        delete map.mIds[args.mId];
    }
    async removeMarkersBymId(args) {
        const map = this.maps[args.id];
        args.mIds.forEach(mId => {
            const id = map.mIds[mId];
            map.markers[id] && (map.markers[id].map = null);
            delete map.markers[id];
            delete map.mIds[mId];
        });
    }
    async getMarkersIds(args) {
        return this.maps[args.id].mIds;
    }
    async updateMarkerBymId(args) {
        await this.removeMarkerBymId({
            id: args.id,
            mId: args.mId
        });
        return (await this.addMarker({ id: args.id, marker: args.marker }));
    }
    async updateMarkersBymId(args) {
        await this.removeMarkersBymId({
            id: args.id,
            mIds: args.mIds
        });
        return (await this.addMarkers({ id: args.id, markers: args.markers }));
    }
    async addPolygons(args) {
        const polygonIds = [];
        const map = this.maps[args.id];
        for (const polygonArgs of args.polygons) {
            const polygon = new google.maps.Polygon(polygonArgs);
            polygon.setMap(map.map);
            const id = '' + this.currPolygonId;
            this.maps[args.id].polygons[id] = polygon;
            this.setPolygonListeners(args.id, id, polygon);
            polygonIds.push(id);
            this.currPolygonId++;
        }
        return { ids: polygonIds };
    }
    async removePolygons(args) {
        const map = this.maps[args.id];
        for (const id of args.polygonIds) {
            map.polygons[id].setMap(null);
            delete map.polygons[id];
        }
    }
    async addCircles(args) {
        const circleIds = [];
        const map = this.maps[args.id];
        for (const circleArgs of args.circles) {
            const circle = new google.maps.Circle(circleArgs);
            circle.setMap(map.map);
            const id = '' + this.currCircleId;
            this.maps[args.id].circles[id] = circle;
            this.setCircleListeners(args.id, id, circle);
            circleIds.push(id);
            this.currCircleId++;
        }
        return { ids: circleIds };
    }
    async removeCircles(args) {
        const map = this.maps[args.id];
        for (const id of args.circleIds) {
            map.circles[id].setMap(null);
            delete map.circles[id];
        }
    }
    async addPolylines(args) {
        const lineIds = [];
        const map = this.maps[args.id];
        for (const polylineArgs of args.polylines) {
            const polyline = new google.maps.Polyline(polylineArgs);
            polyline.set('tag', polylineArgs.tag);
            polyline.setMap(map.map);
            const id = '' + this.currPolylineId;
            this.maps[args.id].polylines[id] = polyline;
            this.setPolylineListeners(args.id, id, polyline);
            lineIds.push(id);
            this.currPolylineId++;
        }
        return {
            ids: lineIds,
        };
    }
    async removePolylines(args) {
        const map = this.maps[args.id];
        for (const id of args.polylineIds) {
            map.polylines[id].setMap(null);
            delete map.polylines[id];
        }
    }
    async enableClustering(_args) {
        var _a;
        const markers = [];
        for (const id in this.maps[_args.id].markers) {
            markers.push(this.maps[_args.id].markers[id]);
        }
        this.maps[_args.id].markerClusterer = new MarkerClusterer({
            map: this.maps[_args.id].map,
            markers: markers,
            algorithm: new SuperClusterAlgorithm({
                minPoints: (_a = _args.minClusterSize) !== null && _a !== void 0 ? _a : 4,
            }),
            onClusterClick: this.onClusterClickHandler,
        });
    }
    async disableClustering(_args) {
        const mapInstance = this.maps[_args.id];
        if (mapInstance.markerClusterer) {
            const markers = Object.values(mapInstance.markers);
            mapInstance.markerClusterer.setMap(null);
            mapInstance.markerClusterer = undefined;
            for (const marker of markers) {
                marker.map = mapInstance.map;
            }
        }
    }
    async onScroll() {
        throw new Error('Method not supported on web.');
    }
    async onResize() {
        throw new Error('Method not supported on web.');
    }
    async onDisplay() {
        throw new Error('Method not supported on web.');
    }
    async create(_args) {
        console.log(`Create map: ${_args.id}`);
        await this.importGoogleLib(_args.apiKey, _args.region, _args.language);
        // Ensure we have a Map ID for Advanced Markers
        const config = Object.assign({}, _args.config);
        if (!config.mapId) {
            config.mapId = `capacitor_map_${this.currMapId++}`;
        }
        this.maps[_args.id] = {
            map: new window.google.maps.Map(_args.element, config),
            element: _args.element,
            markers: {},
            polygons: {},
            circles: {},
            polylines: {},
            mIds: {}
        };
        this.setMapListeners(_args.id);
    }
    async destroy(_args) {
        console.log(`Destroy map: ${_args.id}`);
        const mapItem = this.maps[_args.id];
        mapItem.element.innerHTML = '';
        mapItem.map.unbindAll();
        delete this.maps[_args.id];
    }
    async mapBoundsContains(_args) {
        const bounds = this.getLatLngBounds(_args.bounds);
        const point = new google.maps.LatLng(_args.point.lat, _args.point.lng);
        return { contains: bounds.contains(point) };
    }
    async mapBoundsExtend(_args) {
        const bounds = this.getLatLngBounds(_args.bounds);
        const point = new google.maps.LatLng(_args.point.lat, _args.point.lng);
        bounds.extend(point);
        const result = new LatLngBounds({
            southwest: {
                lat: bounds.getSouthWest().lat(),
                lng: bounds.getSouthWest().lng(),
            },
            center: {
                lat: bounds.getCenter().lat(),
                lng: bounds.getCenter().lng(),
            },
            northeast: {
                lat: bounds.getNorthEast().lat(),
                lng: bounds.getNorthEast().lng(),
            },
        });
        return { bounds: result };
    }
    async takeSnapshot(_args) {
        const snapshot = this.maps[_args.id].map.getDiv();
        return { snapshot: snapshot };
    }
    async addGroundOverlay(_args) {
        throw new Error('Method not supported on web.');
    }
    async getZoomLevel(_args) {
        return {
            zoomLevel: this.maps[_args.id].map.getZoom()
        };
    }
    async hasIcon() {
        return {
            hasIcon: false
        };
    }
    getLatLngBounds(_args) {
        return new google.maps.LatLngBounds(new google.maps.LatLng(_args.southwest.lat, _args.southwest.lng), new google.maps.LatLng(_args.northeast.lat, _args.northeast.lng));
    }
    async setCircleListeners(mapId, circleId, circle) {
        circle.addListener('click', () => {
            this.notifyListeners('onCircleClick', {
                mapId: mapId,
                circleId: circleId,
                tag: circle.get('tag'),
            });
        });
    }
    async setPolygonListeners(mapId, polygonId, polygon) {
        polygon.addListener('click', () => {
            this.notifyListeners('onPolygonClick', {
                mapId: mapId,
                polygonId: polygonId,
                tag: polygon.get('tag'),
            });
        });
    }
    async setPolylineListeners(mapId, polylineId, polyline) {
        polyline.addListener('click', () => {
            this.notifyListeners('onPolylineClick', {
                mapId: mapId,
                polylineId: polylineId,
                tag: polyline.get('tag'),
            });
        });
    }
    async setMarkerListeners(mapId, markerId, mId, marker) {
        marker.addListener('click', () => {
            var _a;
            const position = marker.position;
            this.notifyListeners('onMarkerClick', {
                mapId: mapId,
                markerId: markerId,
                latitude: position.lat,
                longitude: position.lng,
                title: (_a = marker.title) !== null && _a !== void 0 ? _a : '',
                snippet: '',
                mId
            });
        });
        if (marker.gmpDraggable) {
            marker.addListener('dragstart', () => {
                var _a;
                const position = marker.position;
                this.notifyListeners('onMarkerDragStart', {
                    mapId: mapId,
                    markerId: markerId,
                    latitude: position.lat,
                    longitude: position.lng,
                    title: (_a = marker.title) !== null && _a !== void 0 ? _a : '',
                    snippet: '',
                    mId
                });
            });
            marker.addListener('drag', () => {
                var _a;
                const position = marker.position;
                this.notifyListeners('onMarkerDrag', {
                    mapId: mapId,
                    markerId: markerId,
                    latitude: position.lat,
                    longitude: position.lng,
                    title: (_a = marker.title) !== null && _a !== void 0 ? _a : '',
                    snippet: '',
                    mId
                });
            });
            marker.addListener('dragend', () => {
                var _a;
                const position = marker.position;
                this.notifyListeners('onMarkerDragEnd', {
                    mapId: mapId,
                    markerId: markerId,
                    latitude: position.lat,
                    longitude: position.lng,
                    title: (_a = marker.title) !== null && _a !== void 0 ? _a : '',
                    snippet: '',
                    mId
                });
            });
        }
    }
    async setMapListeners(mapId) {
        const map = this.maps[mapId].map;
        map.addListener('idle', async () => {
            var _a, _b;
            const bounds = await this.getMapBounds({ id: mapId });
            this.notifyListeners('onCameraIdle', {
                mapId: mapId,
                bearing: map.getHeading(),
                bounds: bounds,
                latitude: (_a = map.getCenter()) === null || _a === void 0 ? void 0 : _a.lat(),
                longitude: (_b = map.getCenter()) === null || _b === void 0 ? void 0 : _b.lng(),
                tilt: map.getTilt(),
                zoom: map.getZoom(),
            });
        });
        map.addListener('center_changed', () => {
            this.notifyListeners('onCameraMoveStarted', {
                mapId: mapId,
                isGesture: true,
            });
        });
        map.addListener('bounds_changed', async () => {
            var _a, _b;
            const bounds = await this.getMapBounds({ id: mapId });
            this.notifyListeners('onBoundsChanged', {
                mapId: mapId,
                bearing: map.getHeading(),
                bounds: bounds,
                latitude: (_a = map.getCenter()) === null || _a === void 0 ? void 0 : _a.lat(),
                longitude: (_b = map.getCenter()) === null || _b === void 0 ? void 0 : _b.lng(),
                tilt: map.getTilt(),
                zoom: map.getZoom(),
            });
        });
        map.addListener('click', (e) => {
            var _a, _b;
            this.notifyListeners('onMapClick', {
                mapId: mapId,
                latitude: (_a = e.latLng) === null || _a === void 0 ? void 0 : _a.lat(),
                longitude: (_b = e.latLng) === null || _b === void 0 ? void 0 : _b.lng(),
            });
        });
        map.addListener('dblclick', (e) => {
            var _a, _b;
            this.notifyListeners('onMapDoubleClick', {
                mapId: mapId,
                latitude: (_a = e.latLng) === null || _a === void 0 ? void 0 : _a.lat(),
                longitude: (_b = e.latLng) === null || _b === void 0 ? void 0 : _b.lng(),
            });
        });
        map.addListener('zoom_changed', () => {
            this.notifyListeners('onZoomChanged', {
                mapId: mapId,
                zoom: map.getZoom()
            });
        });
        this.notifyListeners('onMapReady', {
            mapId: mapId,
        });
    }
    buildMarkerOpts(marker, map) {
        var _a;
        if (!this.AdvancedMarkerElement || !this.PinElement) {
            throw new Error('Marker library not loaded');
        }
        let content = undefined;
        if (marker.iconUrl) {
            const img = document.createElement('img');
            img.src = marker.iconUrl;
            if (marker.iconSize) {
                img.style.width = `${marker.iconSize.width}px`;
                img.style.height = `${marker.iconSize.height}px`;
            }
            content = img;
        }
        else {
            const pinOptions = {
                scale: (_a = marker.opacity) !== null && _a !== void 0 ? _a : 1,
                glyph: marker.title,
                background: marker.tintColor
                    ? `rgb(${marker.tintColor.r}, ${marker.tintColor.g}, ${marker.tintColor.b})`
                    : undefined,
            };
            const pin = new this.PinElement(pinOptions);
            content = pin.element;
        }
        const advancedMarker = new this.AdvancedMarkerElement({
            position: marker.coordinate,
            map: map,
            content: content,
            title: marker.title,
            gmpDraggable: marker.draggable,
        });
        return advancedMarker;
    }
    removeAllMarkers(mapId) {
        const map = this.maps[mapId];
        const markerIds = Object.keys(map.markers);
        this.removeMarkers({
            id: mapId,
            markerIds: markerIds
        });
    }
}
//# sourceMappingURL=web.js.map