use std::sync::Arc;
use maki_agent::tools::{ToolRegistry, ToolAudience, DescriptionContext, ToolFilter};
use maki_agent::template::Vars;
use maki_providers::Model;

fn main() {
    let registry = ToolRegistry::global();
    let vars = Vars::new();
    let model = Model::from_spec("anthropic/claude-sonnet-4-20250514").unwrap();
    
    let filter = ToolFilter::All;
    let ctx = DescriptionContext {
        filter: &filter,
        audience: ToolAudience::MAIN,
        workflow: false,
    };

    let modes = ["default", "research", "build", "compact"];
    
    println!("Tool definition size by mode:");
    println!("{:<15} {:<15} {:<15}", "Mode", "Tool Count", "Bytes");
    println!("{}", "-".repeat(45));

    for mode in &modes {
        let allowed = registry.active_tools_for_mode(mode, &[]);
        let defs = registry.definitions_filtered(&vars, &ctx, model.supports_tool_examples(), &allowed);
        let bytes = serde_json::to_vec(&defs).unwrap().len();
        let count = allowed.len();
        
        println!("{:<15} {:<15} {:<15}", mode, count, bytes);
    }

    let all_defs = registry.definitions(&vars, &ctx, model.supports_tool_examples());
    let all_bytes = serde_json::to_vec(&all_defs).unwrap().len();
    let all_count = registry.names().len();
    
    println!("{:<15} {:<15} {:<15}", "all (unfiltered)", all_count, all_bytes);
}
