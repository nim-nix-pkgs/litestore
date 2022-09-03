import
  asynchttpserver,
  strutils,
  sequtils,
  cgi,
  strtabs,
  pegs,
  json,
  os,
  times
import
  types,
  contenttypes,
  core,
  utils,
  logger

# Helper procs

proc sqlOp(op: string): string =
  let table = newStringTable()
  table["not eq"] = "<>"
  table["eq"] = "=="
  table["gt"] = ">"
  table["gte"] = ">="
  table["lt"] = "<"
  table["lte"] = "<="
  table["contains"] = "contains"
  table["like"] = "like"
  return table[op]

proc orderByClauses*(str: string): string =
  var clauses = newSeq[string]()
  var fragments = str.split(",")
  let clause = peg"""
    clause <- {[-+]} {field}
    field <- ('id' / 'created' / 'modified' / path)
    path <- '$' (objField)+
    ident <- [a-zA-Z0-9_]+
    objField <- '.' ident
  """
  for f in fragments:
    var matches = @["", ""]
    if f.find(clause, matches) != -1:
      var field = matches[1]
      if field[0] == '$':
        field = "json_extract(documents.data, '$1')" % matches[1]
      if matches[0] == "-":
        clauses.add("$1 COLLATE NOCASE DESC" % field)
      else:
        clauses.add("$1 COLLATE NOCASE ASC" % field)
  return clauses.join(", ")

proc selectClause*(str: string, options: var QueryOptions) =
  let tokens = """
    path <- '$' (objItem / objField)+
    ident <- [a-zA-Z0-9_]+
    objIndex <- '[' \d+ ']'
    objField <- '.' ident
    objItem <- objField objIndex
  """
  let fields = peg("""
    fields <- ^{field} (\s* ',' \s* {field})*$
    field <- path \s+ ('as' / 'AS') \s+ ident
  """ & tokens)
  let field = peg("""
    field <- ^{path} \s+ ('as' / 'AS') \s+ {ident}$
  """ & tokens)
  var fieldMatches = newSeq[string](10)
  if str.strip.match(fields, fieldMatches):
    for m in fieldMatches:
      if m.len > 0:
        var rawTuple = newSeq[string](2)
        if m.match(field, rawTuple):
          options.jsonSelect.add((path: rawTuple[0], alias: rawTuple[1]))

proc filterClauses*(str: string, options: var QueryOptions) =
  let tokens = """
    operator <- 'not eq' / 'eq' / 'gte' / 'gt' / 'lte' / 'lt' / 'contains' / 'like'
    value <- string / number / 'null' / 'true' / 'false'
    string <- '"' ('\\"' . / [^"])* '"'
    number <- '-'? '0' / [1-9] [0-9]* ('.' [0-9]+)? (( 'e' / 'E' ) ( '+' / '-' )? [0-9]+)?
    path <- '$' (objItem / objField)+
    ident <- [a-zA-Z0-9_]+
    objIndex <- '[' \d+ ']'
    objField <- '.' ident
    objItem <- objField objIndex
  """
  let clause = peg("""
    clause <- {path} \s+ {operator} \s+ {value}
  """ & tokens)
  let andClauses = peg("""
    andClauses <- ^{clause} (\s+ 'and' \s+ {clause})*$
    clause <- path \s+ operator \s+ value
  """ & tokens)
  let orClauses = peg("""
    orClauses <- ^{andClauses} (\s+ 'or' \s+ {andClauses})*$
    andClauses <- clause (\s+ 'and' \s+ clause)*
    clause <- path \s+ operator \s+ value
  """ & tokens)
  var orClausesMatches = newSeq[string](10)
  discard str.strip.match(orClauses, orClausesMatches)
  var parsedClauses = newSeq[seq[seq[string]]]()
  for orClause in orClausesMatches:
    if orClause.len > 0:
      var andClausesMatches = newSeq[string](10)
      discard orClause.strip.match(andClauses, andClausesMatches)
      var parsedAndClauses = newSeq[seq[string]]()
      for andClause in andClausesMatches:
        if andClause.len > 0:
          var clauses = newSeq[string](3)
          discard andClause.strip.match(clause, clauses)
          clauses[1] = sqlOp(clauses[1])
          if clauses[2] == "true":
            clauses[2] = "1"
          elif clauses[2] == "false":
            clauses[2] = "0"
          parsedAndClauses.add clauses
      if parsedAndClauses.len > 0:
        parsedClauses.add parsedAndClauses
  if parsedClauses.len == 0:
    return
  var currentArr = 0
  var tables = newSeq[string]()
  let resOrClauses = parsedClauses.map do (it: seq[seq[string]]) -> string:
    let resAndClauses = it.map do (x: seq[string]) -> string:
      if x[1] == "contains":
        currentArr = currentArr + 1
        tables.add "json_each(documents.data, '$1') AS arr$2" % [x[0], $currentArr]
        return "arr$1.value == $2" % [$currentArr, x[2]]
      else:
        var arr = @[x[0], x[1], x[2]]
        if x[1] == "like":
          arr[2] = x[2].replace('*', '%')
        return "json_extract(documents.data, '$1') $2 $3 " % arr
    return resAndClauses.join(" AND ")
  options.tables = options.tables & tables
  options.jsonFilter = resOrClauses.join(" OR ")

proc parseQueryOption*(fragment: string, options: var QueryOptions) =
  if fragment == "":
    return
  var pair = fragment.split('=')
  if pair.len < 2 or pair[1] == "":
    raise newException(EInvalidRequest, "Invalid query string fragment '$1'" % fragment)
  try:
    pair[1] = pair[1].replace("+", "%2B").decodeURL
  except:
    raise newException(EInvalidRequest, "Unable to decode query string fragment '$1'" % fragment)
  case pair[0]:
    of "filter":
      filterClauses(pair[1], options)
      if options.jsonFilter == "":
        raise newException(EInvalidRequest, "Invalid filter clause: $1" % pair[1].replace("\"", "\\\""))
    of "select":
      selectClause(pair[1], options)
      if options.jsonSelect.len == 0:
        raise newException(EInvalidRequest, "Invalid select clause: $1" % pair[1].replace("\"", "\\\""))
    of "like":
      options.like = pair[1]
    of "search":
      options.search = pair[1]
    of "tags":
      options.tags = pair[1]
    of "created-after":
      try:
        options.createdAfter = pair[1].parseInt.fromUnix.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
      except:
        raise newException(EInvalidRequest, "Invalid created-after value: $1" % getCurrentExceptionMsg())
    of "created-before":
      try:
        options.createdBefore = pair[1].parseInt.fromUnix.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
      except:
        raise newException(EInvalidRequest, "Invalid created-before value: $1" % getCurrentExceptionMsg())
    of "modified-after":
      try:
        options.modifiedAfter = pair[1].parseInt.fromUnix.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
      except:
        raise newException(EInvalidRequest, "Invalid modified.after value: $1" % getCurrentExceptionMsg())
    of "modified-before":
      try:
        options.modifiedBefore = pair[1].parseInt.fromUnix.utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")
      except:
        raise newException(EInvalidRequest, "Invalid modified-before value: $1" % getCurrentExceptionMsg())
    of "limit":
      try:
        options.limit = pair[1].parseInt
      except:
        raise newException(EInvalidRequest, "Invalid limit value: $1" % getCurrentExceptionMsg())
    of "offset":
      try:
        options.offset = pair[1].parseInt
      except:
        raise newException(EInvalidRequest, "Invalid offset value: $1" % getCurrentExceptionMsg())
    of "sort":
      let orderby = pair[1].orderByClauses()
      if orderby != "":
        options.orderby = orderby
      else:
        raise newException(EInvalidRequest, "Invalid sort value: $1" % pair[1])
    of "contents", "raw":
      discard
    else:
      discard

proc parseQueryOptions*(querystring: string, options: var QueryOptions) =
  var fragments = querystring.split('&')
  for f in fragments:
    f.parseQueryOption(options)

proc validate*(req: LSRequest, LS: LiteStore, resource: string, id: string, cb: proc(req: LSRequest, LS: LiteStore, resource: string, id: string):LSResponse): LSResponse =
  if req.reqMethod == HttpPost or req.reqMethod == HttpPut or req.reqMethod == HttpPatch:
    var ct =  ""
    let body = req.body.strip
    if body == "":
      return resError(Http400, "Bad request: No content specified for document.")
    if req.headers.hasKey("Content-Type"):
      ct = req.headers["Content-Type"]
      case ct:
        of "application/json":
          try:
            discard body.parseJson()
          except:
            return resError(Http400, "Invalid JSON content - $1" % getCurrentExceptionMsg())
        else:
          discard
  return cb(req, LS, resource, id)

proc patchTag(tags: var seq[string], index: int, op, path, value: string): bool =
  LOG.debug("- PATCH -> $1 tag['$2'] = \"$3\" - Total tags: $4." % [op, $index, $value, $tags.len])
  case op:
    of "remove":
      let tag = tags[index]
      if not tag.startsWith("$"):
        tags[index] = "" # Not removing element, otherwise subsequent indexes won't work!
      else:
        raise newException(EInvalidRequest, "cannot remove system tag: $1" % tag)
    of "add":
      if value.match(PEG_USER_TAG):
        tags.insert(value, index)
      else:
        if value.strip == "":
          raise newException(EInvalidRequest, "tag not specified." % value)
        else:
          raise newException(EInvalidRequest, "invalid tag: $1" % value)
    of "replace":
      if value.match(PEG_USER_TAG):
        if tags[index].startsWith("$"):
          raise newException(EInvalidRequest, "cannot replace system tag: $1" % tags[index])
        else:
          tags[index] = value
      else:
        if value.strip == "":
          raise newException(EInvalidRequest, "tag not specified." % value)
        else:
          raise newException(EInvalidRequest, "invalid tag: $1" % value)
    of "test":
      if tags[index] != value:
        return false
    else:
      raise newException(EInvalidRequest, "invalid patch operation: $1" % op)
  return true

proc patchData*(data: var JsonNode, origData: JsonNode, op: string, path: string, value: JsonNode): bool =
  LOG.debug("- PATCH -> $1 path $2 with $3" % [op, path, $value])
  var keys = path.replace(peg"^\/data\/", "").split("/")
  if keys.len == 0:
    raise newException(EInvalidRequest, "no valid path specified: $1" % path)
  var d = data
  var dorig = origData
  var c = 1
  for key in keys:
    if d.kind == JArray:
      try:
        var index = key.parseInt
        if c >= keys.len:
          d.elems[index] = value
          case op:
            of "remove":
              d.elems.del(index)
            of "add":
              d.elems.insert(value, index)
            of "replace":
              d.elems[index] = value
            of "test":
              if d.elems[index] != value:
                return false
            else:
              raise newException(EInvalidRequest, "invalid patch operation: $1" % op)
        else:
          d = d[index]
          dorig = dorig[index]
      except:
        raise newException(EInvalidRequest, "invalid index key '$1' in path '$2'" % [key, path])
    else:
      if c >= keys.len:
        case op:
          of "remove":
            if d.hasKey(key):
              d.delete(key)
            else:
              raise newException(EInvalidRequest, "key '$1' not found in path '$2'" % [key, path])
          of "add":
            d[key] = value
          of "replace":
            if d.hasKey(key):
              d[key] = value
            else:
              raise newException(EInvalidRequest, "key '$1' not found in path '$2'" % [key, path])
          of "test":
            if dorig.hasKey(key):
              if dorig[key] != value:
                return false
            else:
              raise newException(EInvalidRequest, "key '$1' not found in path '$2'" % [key, path])
          else:
            raise newException(EInvalidRequest, "invalid patch operation: $1" % op)
      else:
        d = d[key]
        dorig = dorig[key]
    c += 1
  return true


proc applyPatchOperation*(data: var JsonNode, origData: JsonNode, tags: var seq[string], op: string, path: string, value: JsonNode): bool =
  var matches = @[""]
  let p = peg"""
    path <- ^tagPath / fieldPath$
    tagPath <- '\/tags\/' {\d+}
    fieldPath <- '\/data\/' ident ('\/' ident)*
    ident <- [a-zA-Z0-9_]+ / '-'
  """
  if path.find(p, matches) == -1:
    raise newException(EInvalidRequest, "cannot patch path '$1'" % path)
  if path.match(peg"^\/tags\/"):
    let index = matches[0].parseInt
    if value.kind != JString:
      raise newException(EInvalidRequest, "tag '$1' is not a string." % $value)
    let tag = value.getStr
    return patchTag(tags, index, op, path, tag)
  elif tags.contains("$subtype:json"):
    return patchData(data, origData, op, path, value)
  else:
    raise newException(EInvalidRequest, "cannot patch data of a non-JSON document.")

# Low level procs

proc getTag*(LS: LiteStore, id: string, options = newQueryOptions(), req: LSRequest): LSResponse =
  let doc = LS.store.retrieveTag(id, options)
  result.headers = ctJsonHeader()
  setOrigin(LS, req, result.headers)
  if doc == newJNull():
    result = resTagNotFound(id)
  else:
    result.content = $doc
    result.code = Http200

proc getIndex*(LS: LiteStore, id: string, options = newQueryOptions(), req: LSRequest): LSResponse =
  let doc = LS.store.retrieveIndex(id, options)
  result.headers = ctJsonHeader()
  setOrigin(LS, req, result.headers)
  if doc == newJNull():
    result = resIndexNotFound(id)
  else:
    result.content = $doc
    result.code = Http200

proc getRawDocument*(LS: LiteStore, id: string, options = newQueryOptions(), req: LSRequest): LSResponse =
  let doc = LS.store.retrieveRawDocument(id, options)
  result.headers = ctJsonHeader()
  setOrigin(LS, req, result.headers)
  if doc == "":
    result = resDocumentNotFound(id)
  else:
    result.content = doc
    result.code = Http200

proc getDocument*(LS: LiteStore, id: string, options = newQueryOptions(), req: LSRequest): LSResponse =
  let doc = LS.store.retrieveDocument(id, options)
  if doc.data == "":
    result = resDocumentNotFound(id)
  else:
    result.headers = doc.contenttype.ctHeader
    setOrigin(LS, req, result.headers)
    result.content = doc.data
    result.code = Http200

proc deleteDocument*(LS: LiteStore, id: string, req: LSRequest): LSResponse =
  let doc = LS.store.retrieveDocument(id)
  if doc.data == "":
    result = resDocumentNotFound(id)
  else:
    try:
      let res = LS.store.destroyDocument(id)
      if res == 0:
        result = resError(Http500, "Unable to delete document '$1'" % id)
      else:
        result.headers = newHttpHeaders(TAB_HEADERS)
        setOrigin(LS, req, result.headers)
        result.headers["Content-Length"] = "0"
        result.content = ""
        result.code = Http204
    except:
      result = resError(Http500, "Unable to delete document '$1'" % id)

proc getTags*(LS: LiteStore, options: QueryOptions = newQueryOptions(), req: LSRequest): LSResponse =
  var options = options
  let t0 = cpuTime()
  let docs = LS.store.retrieveTags(options)
  let orig_limit = options.limit
  let orig_offset = options.offset
  options.limit = 0
  options.offset = 0
  options.select = @["COUNT(tag_id)"]
  let total = LS.store.countTags(prepareSelectTagsQuery(options), options.like.replace("*", "%"))
  var content = newJObject()
  if options.like != "":
    content["like"] = %(options.like.decodeURL)
  if orig_limit > 0:
    content["limit"] = %orig_limit
    if orig_offset > 0:
      content["offset"] = %orig_offset
  content["total"] = %total
  content["execution_time"] = %(cputime()-t0)
  content["results"] = docs
  result.headers = ctJsonHeader()
  setOrigin(LS, req, result.headers)
  result.content = content.pretty
  result.code = Http200

proc getIndexes*(LS: LiteStore, options: QueryOptions = newQueryOptions(), req: LSRequest): LSResponse =
  var options = options
  let t0 = cpuTime()
  let docs = LS.store.retrieveIndexes(options)
  let orig_limit = options.limit
  let orig_offset = options.offset
  options.limit = 0
  options.offset = 0
  options.select = @["COUNT(name)"]
  let total = LS.store.countIndexes(prepareSelectIndexesQuery(options), options.like.replace("*", "%"))
  var content = newJObject()
  if options.like != "":
    content["like"] = %(options.like.decodeURL)
  if orig_limit > 0:
    content["limit"] = %orig_limit
    if orig_offset > 0:
      content["offset"] = %orig_offset
  content["total"] = %total
  content["execution_time"] = %(cputime()-t0)
  content["results"] = docs
  result.headers = ctJsonHeader()
  setOrigin(LS, req, result.headers)
  result.content = content.pretty
  result.code = Http200

proc getRawDocuments*(LS: LiteStore, options: QueryOptions = newQueryOptions(), req: LSRequest): LSResponse =
  var options = options
  let t0 = cpuTime()
  let docs = LS.store.retrieveRawDocuments(options)
  let orig_limit = options.limit
  let orig_offset = options.offset
  options.limit = 0
  options.offset = 0
  options.select = @["COUNT(docid)"]
  let total = LS.store.retrieveRawDocuments(options)[0].num
  var content = newJObject()
  if options.folder != "":
    content["folder"] = %(options.folder)
  if options.search != "":
    content["search"] = %(options.search.decodeURL)
  if options.tags != "":
    content["tags"] = newJArray()
    for tag in options.tags.replace("+", "%2B").decodeURL.split(","):
      content["tags"].add(%tag)
  if orig_limit > 0:
    content["limit"] = %orig_limit
    if orig_offset > 0:
      content["offset"] = %orig_offset
  if options.orderby != "":
    content["sort"] = %options.orderby
  content["total"] = %total
  content["execution_time"] = %(cputime()-t0)
  content["results"] = docs
  result.headers = ctJsonHeader()
  setOrigin(LS, req, result.headers)
  result.content = content.pretty
  result.code = Http200

proc getInfo*(LS: LiteStore, req: LSRequest): LSResponse =
  let info = LS.store.retrieveInfo()
  let version = info[0]
  let total_documents = info[1]
  let total_tags = LS.store.countTags()
  let tags = LS.store.retrieveTagsWithTotals()
  var content = newJObject()
  content["version"] = %(LS.appname & " v" & LS.appversion)
  content["datastore_version"] = %version
  content["size"] = %($((LS.file.getFileSize().float/(1024*1024)).formatFloat(ffDecimal, 2)) & " MB")
  content["read_only"] = %LS.readonly
  content["log_level"] = %LS.loglevel
  if LS.directory.len == 0:
    content["directory"] = newJNull()
  else:
    content["directory"] = %LS.directory
  content["mount"] = %LS.mount
  content["total_documents"] = %total_documents
  content["total_tags"] = %total_tags
  content["tags"] = tags
  result.headers = ctJsonHeader()
  setOrigin(LS, req, result.headers)
  result.content = content.pretty
  result.code = Http200

proc putIndex*(LS: LiteStore, id, field: string, req: LSRequest): LSResponse =
  try:
    if (not id.match(PEG_INDEX)):
      return resError(Http400, "invalid index ID: $1" % id)
    if (not field.match(PEG_JSON_FIELD)):
      return resError(Http400, "invalid field path: $1" % field)
    if (LS.store.retrieveIndex(id) != newJNull()):
      return resError(Http409, "Index already exists: $1" % id)
    LS.store.createIndex(id, field)
    result.headers = ctJsonHeader()
    setOrigin(LS, req, result.headers)
    result.content = "{\"id\": \"$1\", \"field\": \"$2\"}" % [id, field]
    result.code = Http200
  except:
    eWarn()
    result = resError(Http500, "Unable to create index.")

proc deleteIndex*(LS: LiteStore, id: string, req: LSRequest): LSResponse =
  if (not id.match(PEG_INDEX)):
    return resError(Http400, "invalid index ID: $1" % id)
  if (LS.store.retrieveIndex(id) == newJNull()):
    return resError(Http404, "Index not found: $1" % id)
  try:
    LS.store.dropIndex(id)
    result.headers = newHttpHeaders(TAB_HEADERS)
    setOrigin(LS, req, result.headers)
    result.headers["Content-Length"] = "0"
    result.content = ""
    result.code = Http204
  except:
    eWarn()
    result = resError(Http500, "Unable to delete index.")

proc postDocument*(LS: LiteStore, body: string, ct: string, folder="", req: LSRequest): LSResponse =
  if not folder.isFolder:
    return resError(Http400, "Invalid folder specified when creating document: $1" % folder)
  try:
    var doc = LS.store.createDocument(folder, body, ct)
    if doc != "":
      result.headers = ctJsonHeader()
      setOrigin(LS, req, result.headers)
      result.content = doc
      result.code = Http201
    else:
      result = resError(Http500, "Unable to create document.")
  except:
    eWarn()
    result = resError(Http500, "Unable to create document.")

proc putDocument*(LS: LiteStore, id: string, body: string, ct: string, req: LSRequest): LSResponse =
  if id.isFolder:
    return resError(Http400, "Invalid ID '$1' (Document IDs cannot end with '/')." % id)
  let doc = LS.store.retrieveDocument(id)
  if doc.data == "":
    # Create a new document
    var doc = LS.store.createDocument(id, body, ct)
    if doc != "":
      result.headers = ctJsonHeader()
      setOrigin(LS, req, result.headers)
      result.content = doc
      result.code = Http201
    else:
      result = resError(Http500, "Unable to create document.")
  else:
    # Update existing document
    try:
      var doc = LS.store.updateDocument(id, body, ct)
      if doc != "":
        result.headers = ctJsonHeader()
        setOrigin(LS, req, result.headers)
        result.content = doc
        result.code = Http200
      else:
        result = resError(Http500, "Unable to update document '$1'." % id)
    except:
      result = resError(Http500, "Unable to update document '$1'." % id)

proc patchDocument*(LS: LiteStore, id: string, body: string, req: LSRequest): LSResponse =
  var apply = true
  let jbody = body.parseJson
  if jbody.kind != JArray:
    return resError(Http400, "Bad request: PATCH request body is not an array.")
  var options = newQueryOptions()
  options.select = @["documents.id AS id", "created", "modified", "data"]
  let doc = LS.store.retrieveRawDocument(id, options)
  if doc == "":
    return resDocumentNotFound(id)
  let jdoc = doc.parseJson
  var tags = newSeq[string]()
  var origTags = newSeq[string]()
  for tag in jdoc["tags"].items:
    tags.add(tag.str)
    origTags.add(tag.str)
  var data: JsonNode
  var origData: JsonNode
  if tags.contains("$subtype:json"):
    try:
      origData = jdoc["data"].getStr.parseJson
      data = origData.copy
    except:
      discard
  var c = 1
  for item in jbody.items:
    if item.hasKey("op") and item.hasKey("path"):
      if not item.hasKey("value"):
        item["value"] = %""
      try:
        apply = applyPatchOperation(data, origData, tags, item["op"].str, item["path"].str, item["value"])
        if not apply:
          break
      except:
        return resError(Http400, "Bad request - $1" % getCurrentExceptionMsg())
    else:
        return resError(Http400, "Bad request: patch operation #$1 is malformed." % $c)
    c.inc
  if apply:
    if origData.len > 0 and origData != data:
      try:
        var doc = LS.store.updateDocument(id, data.pretty, "application/json")
        if doc == "":
          return resError(Http500, "Unable to patch document '$1'." % id)
      except:
        return resError(Http500, "Unable to patch document '$1' - $2" % id, getCurrentExceptionMsg())
    if origTags != tags:
      try:
        for t1 in jdoc["tags"].items:
          discard LS.store.destroyTag(t1.str, id, true)
        for t2 in tags:
          if t2 != "":
            LS.store.createTag(t2, id, true)
      except:
        return resError(Http500, "Unable to patch document '$1' - $2" % [id, getCurrentExceptionMsg()])
  return LS.getRawDocument(id, newQueryOptions(), req)

# Main routing

proc options*(req: LSRequest, LS: LiteStore, resource: string, id = ""): LSResponse =
  case resource:
    of "info":
      result.headers = newHttpHeaders(TAB_HEADERS)
      setOrigin(LS, req, result.headers)
      result.headers["Allow"] = "GET, OPTIONS"
      result.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
      if id != "":
        return resError(Http404, "Info '$1' not found." % id)
      else:
        result.code = Http204
        result.content = ""
    of "dir":
      result.code = Http204
      result.content = ""
      result.headers = newHttpHeaders(TAB_HEADERS)
      setOrigin(LS, req, result.headers)
      result.headers["Allow"] = "GET, OPTIONS"
      result.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
    of "tags":
      result.code = Http204
      result.content = ""
      result.headers = newHttpHeaders(TAB_HEADERS)
      setOrigin(LS, req, result.headers)
      result.headers["Allow"] = "GET, OPTIONS"
      result.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
    of "indexes":
      result.code = Http204
      result.content = ""
      result.headers = newHttpHeaders(TAB_HEADERS)
      setOrigin(LS, req, result.headers)
      if id != "":
        result.code = Http204
        result.content = ""
        if LS.readonly:
          result.headers["Allow"] = "GET, OPTIONS"
          result.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
        else:
          result.headers["Allow"] = "GET, OPTIONS, PUT, DELETE"
          result.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS, PUT, DELETE"
      else:
        result.code = Http204
        result.content = ""
        if LS.readonly:
          result.headers = newHttpHeaders(TAB_HEADERS)
          setOrigin(LS, req, result.headers)
          result.headers["Allow"] = "GET, OPTIONS"
          result.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
        else:
          result.headers = newHttpHeaders(TAB_HEADERS)
          setOrigin(LS, req, result.headers)
          result.headers["Allow"] = "GET, OPTIONS"
          result.headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
    of "docs":
      var folder: string
      if id.isFolder:
        folder = id
      if folder.len > 0:
        result.code = Http204
        result.content = ""
        if LS.readonly:
          result.headers = newHttpHeaders(TAB_HEADERS)
          setOrigin(LS, req, result.headers)
          result.headers["Allow"] = "HEAD, GET, OPTIONS"
          result.headers["Access-Control-Allow-Methods"] = "HEAD, GET, OPTIONS"
        else:
          result.headers = newHttpHeaders(TAB_HEADERS)
          setOrigin(LS, req, result.headers)
          result.headers["Allow"] = "HEAD, GET, OPTIONS, POST, PUT"
          result.headers["Access-Control-Allow-Methods"] = "HEAD, GET, OPTIONS, POST, PUT"
      elif id != "":
        result.code = Http204
        result.content = ""
        if LS.readonly:
          result.headers = newHttpHeaders(TAB_HEADERS)
          setOrigin(LS, req, result.headers)
          result.headers["Allow"] = "HEAD, GET, OPTIONS"
          result.headers["Access-Control-Allow-Methods"] = "HEAD, GET, OPTIONS"
        else:
          result.headers = newHttpHeaders(TAB_HEADERS)
          setOrigin(LS, req, result.headers)
          result.headers["Allow"] = "HEAD, GET, OPTIONS, PUT, PATCH, DELETE"
          result.headers["Allow-Patch"] = "application/json-patch+json"
          result.headers["Access-Control-Allow-Methods"] = "HEAD, GET, OPTIONS, PUT, PATCH, DELETE"
      else:
        result.code = Http204
        result.content = ""
        if LS.readonly:
          result.headers = newHttpHeaders(TAB_HEADERS)
          setOrigin(LS, req, result.headers)
          result.headers["Allow"] = "HEAD, GET, OPTIONS"
          result.headers["Access-Control-Allow-Methods"] = "HEAD, GET, OPTIONS"
        else:
          result.headers = newHttpHeaders(TAB_HEADERS)
          setOrigin(LS, req, result.headers)
          result.headers["Allow"] = "HEAD, GET, OPTIONS, POST"
          result.headers["Access-Control-Allow-Methods"] = "HEAD, GET, OPTIONS, POST"
    else:
      discard # never happens really.

proc head*(req: LSRequest, LS: LiteStore, resource: string, id = ""): LSResponse =
  var options = newQueryOptions()
  options.select = @["documents.id AS id", "created", "modified"]
  if id.isFolder:
    options.folder = id
  try:
    parseQueryOptions(req.url.query, options);
    if id != "" and options.folder == "":
      result = LS.getRawDocument(id, options, req)
      result.content = ""
    else:
      result = LS.getRawDocuments(options, req)
      result.content = ""
  except:
    return resError(Http400, "Bad request - $1" % getCurrentExceptionMsg())

proc get*(req: LSRequest, LS: LiteStore, resource: string, id = ""): LSResponse =
  case resource:
    of "docs":
      var options = newQueryOptions()
      if id.isFolder:
        options.folder = id
      if req.url.query.contains("contents=false"):
        options.select = @["documents.id AS id", "created", "modified"]
      try:
        parseQueryOptions(req.url.query, options);
        if id != "" and options.folder == "":
          if req.url.query.contains("raw=true") or req.headers.hasKey("Accept") and req.headers["Accept"] == "application/json":
            return LS.getRawDocument(id, options, req)
          else:
            return LS.getDocument(id, options, req)
        else:
          return LS.getRawDocuments(options, req)
      except:
        let e = getCurrentException()
        let trace = e.getStackTrace()
        echo trace
        return resError(Http400, "Bad Request - $1" % getCurrentExceptionMsg())
    of "tags":
      var options = newQueryOptions()
      try:
        parseQueryOptions(req.url.query, options);
        if id != "":
          return LS.getTag(id, options, req)
        else:
          return LS.getTags(options, req)
      except:
        return resError(Http400, "Bad Request - $1" % getCurrentExceptionMsg())
    of "indexes":
      var options = newQueryOptions()
      try:
        parseQueryOptions(req.url.query, options);
        if id != "":
          return LS.getIndex(id, options, req)
        else:
          return LS.getIndexes(options, req)
      except:
        return resError(Http400, "Bad Request - $1" % getCurrentExceptionMsg())
    of "info":
      if id != "":
        return resError(Http404, "Info '$1' not found." % id)
      return LS.getInfo(req)
    else:
      discard # never happens really.

proc post*(req: LSRequest, LS: LiteStore, resource: string, id = ""): LSResponse =
  var ct = "text/plain"
  if req.headers.hasKey("Content-Type"):
    ct = req.headers["Content-Type"]
  return LS.postDocument(req.body.strip, ct, id, req)

proc put*(req: LSRequest, LS: LiteStore, resource: string, id = ""): LSResponse =
  if id != "":
    if resource == "indexes":
      var field = ""
      try:
        field = parseJson(req.body.strip)["field"].getStr
      except:
        return resError(Http400, "Bad Request - Invalid JSON body - $1" % getCurrentExceptionMsg())
      return LS.putIndex(id, field, req)
    else: # Assume docs
      var ct = "text/plain"
      if req.headers.hasKey("Content-Type"):
        ct = req.headers["Content-Type"]
      return LS.putDocument(id, req.body.strip, ct, req)
  else:
    return resError(Http400, "Bad request: document ID must be specified in PUT requests.")

proc delete*(req: LSRequest, LS: LiteStore, resource: string, id = ""): LSResponse =
  if id != "":
    if resource == "indexes":
      return LS.deleteIndex(id, req)
    else: # Assume docs
      return LS.deleteDocument(id, req)
  else:
    return resError(Http400, "Bad request: document ID must be specified in DELETE requests.")

proc patch*(req: LSRequest, LS: LiteStore, resource: string, id = ""): LSResponse =
  if id != "":
    return LS.patchDocument(id, req.body, req)
  else:
    return resError(Http400, "Bad request: document ID must be specified in PATCH requests.")

proc serveFile*(req: LSRequest, LS: LiteStore, id: string): LSResponse =
  let path = LS.directory / id
  var reqMethod = $req.reqMethod
  if req.headers.hasKey("X-HTTP-Method-Override"):
    reqMethod = req.headers["X-HTTP-Method-Override"]
  case reqMethod.toUpperAscii:
    of "OPTIONS":
      return validate(req, LS, "dir", id, options)
    of "GET":
      if path.fileExists:
        try:
          let contents = path.readFile
          let parts = path.splitFile
          if CONTENT_TYPES.hasKey(parts.ext):
            result.headers = CONTENT_TYPES[parts.ext].ctHeader
          else:
            result.headers = ctHeader("text/plain")
          setOrigin(LS, req, result.headers)
          result.content = contents
          result.code = Http200
        except:
          return resError(Http500, "Unable to read file '$1'." % path)
      else:
        return resError(Http404, "File '$1' not found." % path)
    else:
      return resError(Http405, "Method not allowed: $1" % $req.reqMethod)

proc route*(req: LSRequest, LS: LiteStore, resource = "docs", id = ""): LSResponse =
  var reqMethod = $req.reqMethod
  if req.headers.hasKey("X-HTTP-Method-Override"):
    reqMethod = req.headers["X-HTTP-Method-Override"]
  case reqMethod.toUpperAscii:
    of "POST":
      if LS.readonly:
        return resError(Http405, "Method not allowed: $1" % $req.reqMethod)
      return validate(req, LS, resource, id, post)
    of "PUT":
      if LS.readonly:
        return resError(Http405, "Method not allowed: $1" % $req.reqMethod)
      return validate(req, LS, resource, id, put)
    of "DELETE":
      if LS.readonly:
        return resError(Http405, "Method not allowed: $1" % $req.reqMethod)
      return validate(req, LS, resource, id, delete)
    of "HEAD":
      return validate(req, LS, resource, id, head)
    of "OPTIONS":
      return validate(req, LS, resource, id, options)
    of "GET":
      return validate(req, LS, resource, id, get)
    of "PATCH":
      if LS.readonly:
        return resError(Http405, "Method not allowed: $1" % $req.reqMethod)
      return validate(req, LS, resource, id, patch)
    else:
      return resError(Http405, "Method not allowed: $1" % $req.reqMethod)
