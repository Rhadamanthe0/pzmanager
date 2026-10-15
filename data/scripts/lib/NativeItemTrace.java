import java.nio.*;
import java.util.*;
import org.json.*;
import zombie.inventory.*;
import zombie.inventory.types.*;

/** Exact boundaries reported by real loader calls, including nested bags.
 * Error (not Exception) prevents the game's tolerant catch from hiding loss. */
public final class NativeItemTrace {
    private static ByteBuffer root;
    private static final ArrayDeque<JSONObject> stack=new ArrayDeque<>();
    private static final List<JSONObject> records=new ArrayList<>();
    public static final class Refusal extends Error {
        Refusal(String message) { super(message); }
    }
    public static void begin(ByteBuffer input) {
        if(root!=null) throw new Refusal("Nested storage validation");
        root=input; stack.clear();records.clear();
    }
    public static JSONArray finish() {
        if(root==null || !stack.isEmpty()) throw new Refusal("Incomplete native inventory trace");
        root=null;
        return new JSONArray(records);
    }
    public static void enter(ByteBuffer input,int version) {
        if(root==null) return;
        if(input!=root || version!=249 || input.remaining()<11) throw new Refusal("Unsupported inventory buffer/version");
        int start=input.position(),length=input.getInt(start);
        long end=(long)start+4+length;
        if(length<7 || end>input.limit() || end>Integer.MAX_VALUE) throw new Refusal("Invalid inventory boundary");
        if(!stack.isEmpty() && end>stack.peek().getInt("record_end")) throw new Refusal("Child outside parent item");
        JSONObject record=new JSONObject().put("record_start",start).put("record_end",(int)end)
            .put("registry_id",(int)input.getShort(start+4)).put("parent",stack.isEmpty()?-1:stack.peek().getInt("record_start"));
        stack.push(record);records.add(record);
    }
    public static void consumed(ByteBuffer input) {
        if(root==null) return;
        if(input!=root || stack.isEmpty() || input.position()!=stack.peek().getInt("record_end"))
            throw new Refusal("Native item loader did not consume its complete envelope");
        stack.peek().put("consumed",true);
    }
    public static void exit(InventoryItem item,ByteBuffer input) {
        if(root==null) return;
        if(input!=root || stack.isEmpty()) throw new Refusal("Unbalanced native inventory trace");
        JSONObject record=stack.pop();
        if(item==null || !record.optBoolean("consumed") || input.position()!=record.getInt("record_end"))
            throw new Refusal("Native loader ignored or truncated item rid="+record.getInt("registry_id")+" at "+record.getInt("record_start")+" consumed="+record.optBoolean("consumed")+" null="+(item==null));
        String kind=item instanceof Literature?"Literature":item instanceof InventoryContainer?"InventoryContainer":item.getClass().getSimpleName();
        record.remove("consumed");record.put("class",kind).put("itemType",item.getFullType()).put("itemId",item.getID());
    }
}
