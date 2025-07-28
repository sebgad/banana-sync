import 'package:xml/xml.dart';

class MultiStatus {
  final List<Response> response;

  MultiStatus({required this.response});

  factory MultiStatus.fromXml(XmlElement element) {
    final responses = element
        .findElements('response')
        .map((e) => Response.fromXml(e))
        .toList();

    return MultiStatus(response: responses);
  }
}

class Prop {
  final String? getcontenttype;
  final String? displayname;
  final String? getlastmodified;
  final ResourceType? resourcetype;
  final String? getcontentlength;
  final int? usedBytes;
  final int? availableBytes;
  final String? etag;

  Prop({
    this.getcontenttype,
    this.displayname,
    this.getlastmodified,
    this.resourcetype,
    this.getcontentlength,
    this.usedBytes,
    this.availableBytes,
    this.etag,
  });

  factory Prop.fromXml(XmlElement element) {
    return Prop(
      getcontenttype: element.getElement('getcontenttype')?.text,
      displayname: element.getElement('displayname')?.text,
      getlastmodified: element.getElement('getlastmodified')?.text,
      resourcetype: ResourceType.fromXmlOrNull(
        element.getElement('resourcetype'),
      ),
      getcontentlength: element.getElement('getcontentlength')?.text,
      usedBytes: _tryParseInt(element.getElement('quota-used-bytes')?.text),
      availableBytes: _tryParseInt(
        element.getElement('quota-available-bytes')?.text,
      ),
      etag: element.getElement('getetag')?.text,
    );
  }

  static int? _tryParseInt(String? value) {
    if (value == null) return null;
    return int.tryParse(value);
  }
}

class PropStat {
  final Prop prop;
  final String status;

  PropStat({required this.prop, required this.status});

  factory PropStat.fromXml(XmlElement element) {
    final propElement = element.getElement('prop');
    if (propElement == null) {
      throw Exception('Missing <prop> element in PropStat');
    }

    final statusText = element.getElement('status')?.text;
    if (statusText == null) {
      throw Exception('Missing <status> element in PropStat');
    }

    return PropStat(prop: Prop.fromXml(propElement), status: statusText);
  }
}

class ResourceType {
  final String? collection;

  ResourceType({this.collection});

  factory ResourceType.fromXml(XmlElement element) {
    final collectionElement = element.getElement('collection');
    final collectionValue = collectionElement?.text.isNotEmpty == true
        ? collectionElement!.text
        : (collectionElement != null ? '' : null);

    return ResourceType(collection: collectionValue);
  }

  static ResourceType? fromXmlOrNull(XmlElement? element) {
    if (element == null) return null;
    return ResourceType.fromXml(element);
  }
}

class Response {
  final String href;
  final PropStat propstat;

  Response({required this.href, required this.propstat});

  factory Response.fromXml(XmlElement element) {
    final hrefElement = element.getElement('href');
    final propstatElement = element.getElement('propstat');

    if (hrefElement == null) {
      throw Exception('Missing <href> element');
    }
    if (propstatElement == null) {
      throw Exception('Missing <propstat> element');
    }

    return Response(
      href: hrefElement.text,
      propstat: PropStat.fromXml(propstatElement),
    );
  }
}
