import java.nio.*;
import java.nio.file.*;
import java.lang.reflect.*;
import java.security.MessageDigest;
import java.util.*;
import org.json.*;
import sun.misc.Unsafe;
import se.krka.kahlua.j2se.*;
import se.krka.kahlua.vm.*;
import zombie.Lua.LuaManager;
import zombie.inventory.*;
import zombie.inventory.types.*;
import zombie.network.GameServer;
import zombie.ZomboidFileSystem;
import zombie.GameWindow;
import zombie.world.WorldDictionary;

/** Read-only validation of copied before/after item records, using the game loaders.
 * Never calls save(), starts the server, or reads a live world. */
public final class ValidateWritingRecords {
 private static final Unsafe UNSAFE;
 static { try { Field f=Unsafe.class.getDeclaredField("theUnsafe");f.setAccessible(true);UNSAFE=(Unsafe)f.get(null); }
          catch(Exception e){throw new ExceptionInInitializerError(e);} }
 private static String hash(byte[] b)throws Exception{return HexFormat.of().formatHex(MessageDigest.getInstance("SHA-256").digest(b));}
 private static void check(boolean condition,String message){if(!condition)throw new IllegalStateException(message);}
 private static Object field(Object object,Class<?> owner,String name)throws Exception{Field f=owner.getDeclaredField(name);f.setAccessible(true);return f.get(object);}
 private static String canonical(Object object){
  if(object==null)return "null";
  if(object instanceof KahluaTable table){TreeMap<String,String> sorted=new TreeMap<>();KahluaTableIterator it=table.iterator();while(it.advance())sorted.put(canonical(it.getKey()),canonical(it.getValue()));return "table"+sorted;}
  if(object instanceof Map<?,?> map){TreeMap<String,String> sorted=new TreeMap<>();for(var e:map.entrySet())sorted.put(canonical(e.getKey()),canonical(e.getValue()));return "map"+sorted;}
  if(object instanceof List<?> list){List<String> out=new ArrayList<>();for(Object v:list)out.add(canonical(v));return "list"+out;}
  if(object instanceof byte[] bytes)return "bytes"+Arrays.toString(bytes);
  if(object instanceof ByteBuffer buffer){ByteBuffer copy=buffer.duplicate();copy.clear();byte[] bytes=new byte[copy.remaining()];copy.get(bytes);return "buffer"+Arrays.toString(bytes);}
  if(object instanceof String s)return "String:"+JSONObject.quote(s);
  if(object instanceof Number||object instanceof Boolean||object instanceof Enum<?>)return object.getClass().getSimpleName()+":"+object;
  return "object:"+object.getClass().getName();
 }
 private static Map<String,String> fields(Object object)throws Exception{
  Map<String,String> out=new TreeMap<>();
  for(Class<?> c=object.getClass();c!=Object.class;c=c.getSuperclass())for(Field f:c.getDeclaredFields()){
   if(Modifier.isStatic(f.getModifiers()))continue;
   if(c==InventoryItem.class&&f.getName().equals("table"))continue;
   if(c==InventoryContainer.class&&f.getName().equals("container"))continue;
   f.setAccessible(true);out.put(c.getName()+"."+f.getName(),canonical(f.get(object)));
  }return out;
 }
 private static InventoryItem allocated(Class<? extends InventoryItem> cls)throws Exception{
  InventoryItem item=(InventoryItem)UNSAFE.allocateInstance(cls);
  Field script=InventoryItem.class.getDeclaredField("scriptItem");script.setAccessible(true);script.set(item,UNSAFE.allocateInstance(zombie.scripting.objects.Item.class));
  if(cls==InventoryContainer.class){Field container=InventoryContainer.class.getDeclaredField("container");container.setAccessible(true);container.set(item,new ItemContainer());}
  return item;
 }
 private static InventoryItem load(byte[] bytes,int version,int offset,String kind)throws Exception{
  ByteBuffer b=ByteBuffer.wrap(bytes);
  check(bytes.length>=offset&&b.getInt()==bytes.length-4,"Invalid item envelope length");
  check(offset==7,"Unexpected item body offset");
  Class<? extends InventoryItem> cls=switch(kind){case "Literature"->Literature.class;case "InventoryContainer"->InventoryContainer.class;default->throw new IllegalStateException("Unsupported item class "+kind);};
  InventoryItem item=allocated(cls);b.position(offset);item.load(b,version);
  check(b.position()==bytes.length,"Game loader did not reach exact item boundary: "+kind+" at "+b.position()+" of "+bytes.length);
  return item;
 }
 private record Bounds(int start,int end,int baseEnd){}
 private static Bounds bounds(byte[] bytes,int version)throws Exception{
  ByteBuffer b=ByteBuffer.wrap(bytes);b.position(7);b.getInt();int flags=Byte.toUnsignedInt(b.get());
  if((flags&1)!=0)b.getInt(); // Current uses; flag 2 has no payload in world version 249.
  if((flags&4)!=0)b.get();
  if((flags&8)!=0)new zombie.core.skinnedmodel.visual.ItemVisual().load(b,version);
  if((flags&16)!=0)b.position(b.position()+4);
  if((flags&32)!=0)b.getFloat();
  int start=-1,end=-1;
  if((flags&64)!=0){int extra=b.getInt();if((extra&1)!=0){start=b.position();KahluaTable table=LuaManager.platform.newTable();table.load(b,version);end=b.position();}}
  ByteBuffer full=ByteBuffer.wrap(bytes);full.position(7);allocated(InventoryItem.class).load(full,version);
  return new Bounds(start,end,full.position());
 }
 private static void compareUntouchedBytes(byte[] before,byte[] after,int version,String kind)throws Exception{
  Bounds a=bounds(before,version),b=bounds(after,version);
  check((a.start<0)==(b.start<0),"ModData presence changed");
  if(a.start<0){check(Arrays.equals(Arrays.copyOfRange(before,4,a.baseEnd),Arrays.copyOfRange(after,4,b.baseEnd)),"Serialized item base fields changed");}
  else {check(Arrays.equals(Arrays.copyOfRange(before,4,a.start),Arrays.copyOfRange(after,4,b.start)),"Serialized fields before modData changed");
   int endA=kind.equals("Literature")?before.length:a.baseEnd,endB=kind.equals("Literature")?after.length:b.baseEnd;
   check(Arrays.equals(Arrays.copyOfRange(before,a.end,endA),Arrays.copyOfRange(after,b.end,endB)),"Serialized fields/text after modData changed");}
 }
 private static void removeDrawings(KahluaTable modData){
  Object value=modData.rawget("NeatWriting");if(!(value instanceof KahluaTable doc))return;
  Object pages=doc.rawget("p");if(!(pages instanceof KahluaTable p))return; // Preserve maps/root documents without pages.
  doc.rawset("ink",null);doc.rawset("sym",null);
  KahluaTableIterator it=p.iterator();while(it.advance())if(it.getValue() instanceof KahluaTable page){page.rawset("ink",null);page.rawset("sym",null);}
 }
 private record Group(int count,byte[] record,byte[] duplicateIds){}
 private record Contents(int id,int reduction,String type,byte explored,List<Group> groups,byte looted,int capacity){}
 private static Contents contents(byte[] bytes,int version)throws Exception{
  ByteBuffer b=ByteBuffer.wrap(bytes);b.position(7);
  InventoryItem base=allocated(InventoryItem.class);base.load(b,version);
  int id=b.getInt(),reduction=b.getInt();String type=GameWindow.ReadString(b);byte explored=b.get();int groups=b.getShort();
  check(groups>=0,"Negative compressed-item group count");List<Group> out=new ArrayList<>();
  for(int i=0;i<groups;i++){
   int count=b.getInt();check(count>0,"Invalid item repetition count");int start=b.position();int length=b.getInt();
   check(length>=3&&length<=b.remaining(),"Invalid compressed child item size");b.position(start);
   byte[] record=new byte[4+length];b.get(record);
   long duplicateLength=4L*(count-1);check(duplicateLength<=b.remaining(),"Invalid duplicate item IDs");
   byte[] ids=new byte[(int)duplicateLength];b.get(ids);out.add(new Group(count,record,ids));
  }
  byte looted=b.get();int capacity=b.getInt();check(b.position()==bytes.length,"Unparsed inventory container bytes");
  return new Contents(id,reduction,type,explored,out,looted,capacity);
 }
 private static void compareContents(byte[] before,byte[] after,int version,Set<String> allowed)throws Exception{
  Contents a=contents(before,version),b=contents(after,version);
  check(a.id==b.id&&a.reduction==b.reduction&&Objects.equals(a.type,b.type)&&a.explored==b.explored&&a.looted==b.looted&&a.capacity==b.capacity,"Inventory container identity/settings changed");
  check(a.groups.size()==b.groups.size(),"Inventory container item group count changed");
  for(int i=0;i<a.groups.size();i++){
   Group x=a.groups.get(i),y=b.groups.get(i);
   check(x.count==y.count&&Arrays.equals(x.duplicateIds,y.duplicateIds),"Inventory container item IDs/multiplicity/order changed");
   if(!Arrays.equals(x.record,y.record))check(allowed.contains(hash(x.record)+":"+hash(y.record)),"Changed child item lacks independent before/after loader validation");
  }
 }
 public static void main(String[] args)throws Exception{
  check(args.length==1,"Usage: ValidateWritingRecords MANIFEST_JSON");
  GameServer.server=true;LuaManager.platform=J2SEPlatform.getInstance();
  ZomboidFileSystem.instance.setCacheDir(Path.of("cache").toAbsolutePath().toString());
  // A standalone probe has no loaded script catalog. The real container loader skips
  // unresolved child types; their identities/order/bytes are therefore also compared
  // independently below, and every changed child is validated as its own record.
  Class<?> dc=Class.forName("zombie.world.DictionaryData");Constructor<?> ctor=dc.getDeclaredConstructor();ctor.setAccessible(true);
  Field dictionary=WorldDictionary.class.getDeclaredField("data");dictionary.setAccessible(true);dictionary.set(null,ctor.newInstance());
  JSONObject manifest=new JSONObject(Files.readString(Path.of(args[0])));JSONArray records=manifest.getJSONArray("records");
  Set<String> allowed=new HashSet<>();
  for(int i=0;i<records.length();i++){JSONObject r=records.getJSONObject(i);byte[] a=Files.readAllBytes(Path.of(r.getString("before"))),b=Files.readAllBytes(Path.of(r.getString("after")));allowed.add(hash(a)+":"+hash(b));}
  int books=0,bags=0;
  for(int i=0;i<records.length();i++){
   JSONObject r=records.getJSONObject(i);int version=r.getInt("worldVersion"),offset=r.optInt("bodyOffset",7);String kind=r.getString("class");
   check(version==249,"Unsupported world version "+version);
   byte[] a=Files.readAllBytes(Path.of(r.getString("before"))),b=Files.readAllBytes(Path.of(r.getString("after")));
   check(Arrays.equals(Arrays.copyOfRange(a,4,7),Arrays.copyOfRange(b,4,7)),"Registry ID or save subtype changed");
   InventoryItem before=load(a,version,offset,kind),after=load(b,version,offset,kind);
   compareUntouchedBytes(a,b,version,kind);
   check(before.getID()==after.getID(),"Item identity changed");
   check(fields(before).equals(fields(after)),"Item fields/customPages/lockedBy changed in record "+i);
   if(kind.equals("Literature")){removeDrawings(before.getModData());books++;}
   else {bags++;check(fields(((InventoryContainer)before).getItemContainer()).equals(fields(((InventoryContainer)after).getItemContainer())),"Container metadata/item count changed");compareContents(a,b,version,allowed);}
   check(canonical(before.getModData()).equals(canonical(after.getModData())),"Non-drawing modData/text/notes/positions changed in record "+i);
  }
  System.out.println("PASS: "+books+" Literature records and "+bags+" InventoryContainer ancestors; exact loader boundaries; only permitted ink/sym removed; texts, other modData, container identities, child IDs/order/multiplicity and unchanged child bytes preserved.");
 }
}
